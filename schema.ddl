-- ============================================================
-- 1. CLEANUP & EXTENSION SETUP
-- ============================================================
DROP TABLE IF EXISTS resource_tags CASCADE;
DROP TABLE IF EXISTS tags CASCADE;
DROP TABLE IF EXISTS comment_threads CASCADE;
DROP TABLE IF EXISTS bookmarks CASCADE;
DROP TABLE IF EXISTS votes CASCADE;
DROP TABLE IF EXISTS resources CASCADE;
DROP TABLE IF EXISTS subjects CASCADE;
DROP TABLE IF EXISTS departments CASCADE;
DROP TABLE IF EXISTS users CASCADE;

DROP TYPE IF EXISTS file_type_enum CASCADE;
DROP TYPE IF EXISTS vote_type_enum CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- 2. CUSTOM ENUM TYPES
-- ============================================================
CREATE TYPE file_type_enum AS ENUM ('notes', 'question_paper', 'reference_link', 'syllabus', 'other');
CREATE TYPE vote_type_enum AS ENUM ('upvote', 'downvote');

-- ============================================================
-- 3. TABLE DEFINITIONS
-- ============================================================
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    uploads_count INT DEFAULT 0 CHECK (uploads_count >= 0),
    reputation_score INT DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE departments (
    department_id SERIAL PRIMARY KEY,
    department_name VARCHAR(100) UNIQUE NOT NULL,
    department_code VARCHAR(10) UNIQUE NOT NULL
);

CREATE TABLE subjects (
    subject_id SERIAL PRIMARY KEY,
    subject_name VARCHAR(100) NOT NULL,
    subject_code VARCHAR(20) UNIQUE NOT NULL,
    semester INT NOT NULL CHECK (semester BETWEEN 1 AND 8),
    department_id INT NOT NULL REFERENCES departments(department_id) ON DELETE CASCADE
);

CREATE TABLE resources (
    resource_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL,
    description TEXT,
    file_url VARCHAR(500) NOT NULL,
    file_type file_type_enum NOT NULL,
    file_size_bytes BIGINT,
    file_hash VARCHAR(64) UNIQUE,
    uploaded_by INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    subject_id INT NOT NULL REFERENCES subjects(subject_id) ON DELETE CASCADE,
    views_count INT DEFAULT 0 CHECK (views_count >= 0),
    upvotes_count INT DEFAULT 0 CHECK (upvotes_count >= 0),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE votes (
    vote_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    resource_id INT NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    vote_type vote_type_enum NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_user_resource_vote UNIQUE (user_id, resource_id)
);

CREATE TABLE bookmarks (
    bookmark_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    resource_id INT NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_user_resource_bookmark UNIQUE (user_id, resource_id)
);

CREATE TABLE comment_threads (
    comment_id SERIAL PRIMARY KEY,
    resource_id INT NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    user_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    parent_comment_id INT REFERENCES comment_threads(comment_id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE tags (
    tag_id SERIAL PRIMARY KEY,
    tag_name VARCHAR(50) UNIQUE NOT NULL
);

CREATE TABLE resource_tags (
    resource_id INT REFERENCES resources(resource_id) ON DELETE CASCADE,
    tag_id INT REFERENCES tags(tag_id) ON DELETE CASCADE,
    PRIMARY KEY (resource_id, tag_id)
);

-- ============================================================
-- 4. INDEXES
-- ============================================================
CREATE INDEX idx_resources_subject ON resources(subject_id);
CREATE INDEX idx_subjects_dept_sem ON subjects(department_id, semester);
CREATE INDEX idx_resources_trending ON resources(created_at DESC, upvotes_count DESC);
CREATE INDEX idx_resources_file_hash ON resources(file_hash);
CREATE INDEX idx_resources_title_trgm ON resources USING gin (title gin_trgm_ops);

-- ============================================================
-- 5. AUTOMATED GAMIFICATION TRIGGERS
-- ============================================================
CREATE OR REPLACE FUNCTION update_user_stats_on_upload()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE users 
    SET uploads_count = uploads_count + 1,
        reputation_score = reputation_score + 10
    WHERE user_id = NEW.uploaded_by;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_resource_insert
AFTER INSERT ON resources
FOR EACH ROW
EXECUTE FUNCTION update_user_stats_on_upload();

CREATE OR REPLACE FUNCTION update_reputation_on_vote()
RETURNS TRIGGER AS $$
DECLARE
    resource_author INT;
BEGIN
    SELECT uploaded_by INTO resource_author FROM resources WHERE resource_id = NEW.resource_id;
    
    IF (NEW.vote_type = 'upvote') THEN
        UPDATE users SET reputation_score = reputation_score + 5 WHERE user_id = resource_author;
        UPDATE resources SET upvotes_count = upvotes_count + 1 WHERE resource_id = NEW.resource_id;
    ELSIF (NEW.vote_type = 'downvote') THEN
        UPDATE users SET reputation_score = reputation_score - 2 WHERE user_id = resource_author;
        UPDATE resources SET upvotes_count = GREATEST(0, upvotes_count - 1) WHERE resource_id = NEW.resource_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_vote_insert
AFTER INSERT ON votes
FOR EACH ROW
EXECUTE FUNCTION update_reputation_on_vote();

-- ============================================================
-- 6. SAFE DATA SEEDING (ORDER-GUARANTEED VIA CTEs)
-- ============================================================
WITH inserted_dept AS (
    INSERT INTO departments (department_name, department_code) 
    VALUES ('Computer Science', 'CSE')
    RETURNING department_id
),
inserted_subj AS (
    INSERT INTO subjects (subject_name, subject_code, semester, department_id) 
    SELECT 'Data Structures', 'CS201', 3, department_id FROM inserted_dept
    RETURNING subject_id
),
inserted_user AS (
    INSERT INTO users (username, email, password_hash) 
    VALUES ('alice_dev', 'alice@example.com', 'securehash123')
    RETURNING user_id
)
INSERT INTO resources (title, description, file_url, file_type, file_hash, uploaded_by, subject_id)
SELECT 
    'DS Trees & Graphs Notes', 
    'Detailed handwritten lecture notes.', 
    'https://storage.example.com/notes1.pdf', 
    'notes', 
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 
    u.user_id, 
    s.subject_id
FROM inserted_user u, inserted_subj s;

-- Check if user 'alice_dev' was created with updated stats (+10 rep, 1 upload)
SELECT user_id, username, email, uploads_count, reputation_score 
FROM users;

-- Check if the sample resource was linked correctly to the user and subject
SELECT resource_id, title, file_type, file_hash, uploaded_by, subject_id 
FROM resources;


INSERT INTO resources (title, description, file_url, file_type, file_hash, uploaded_by, subject_id)
VALUES (
    'Duplicate DS Notes', 
    'Testing duplicate detection', 
    'https://storage.example.com/duplicate.pdf', 
    'notes', 
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 
    1, 
    1
);


-- Upvote the resource (user 1 upvotes resource 1)
INSERT INTO votes (user_id, resource_id, vote_type) 
VALUES (1, 1, 'upvote');

-- Check updated upvote count on resource and reputation on user
SELECT title, upvotes_count FROM resources WHERE resource_id = 1;
SELECT username, reputation_score FROM users WHERE user_id = 1;