-- 01_cleaning.sql
-- Project: Layoffs EDA | Database: layoff_data
-- Raw table: dbo.layoffs (never changed)
-- Work table: dbo.layoffs_staging (all cleaning happens here)
-- Safe to re-run from the top: it rebuilds the staging table each time.

USE layoff_data;
GO


----------------------------------------------------------------------
-- STEP 1: Create the staging table
----------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.layoffs_staging;
GO

SELECT *
INTO dbo.layoffs_staging
FROM dbo.layoffs;
GO

SELECT COUNT(*) AS staging_rows 
FROM dbo.layoffs_staging;   -- expect 2361
GO


----------------------------------------------------------------------
-- STEP 2: Look at the data (nothing is changed)
----------------------------------------------------------------------
SELECT DISTINCT industry 
FROM dbo.layoffs_staging 
ORDER BY industry;

SELECT DISTINCT country  
FROM dbo.layoffs_staging 
ORDER BY country;

SELECT DISTINCT stage    
FROM dbo.layoffs_staging 
ORDER BY stage;
GO


----------------------------------------------------------------------
-- STEP 3: Remove exact duplicates (identical in every column)
----------------------------------------------------------------------
WITH dup_cte AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY company, location, industry, total_laid_off,
                            percentage_laid_off, date, stage, country,
                            funds_raised_millions
               ORDER BY (SELECT NULL)
           ) AS row_num
    FROM dbo.layoffs_staging
)
DELETE FROM dup_cte
WHERE row_num > 1;
GO

SELECT COUNT(*) AS rows_after_step3 
FROM dbo.layoffs_staging;   -- expect 2356
GO


----------------------------------------------------------------------
-- STEP 4: Same event entered twice (same company + same date)
--   Removing 4 rows from 3 companies:
--     Bybit    - the empty row (no headcount, no percentage)
--     Terminus - the row with stage 'Unknown'
--     Oda      - the Sweden row and the Norway 6% row
--   Kept (numbers or cities differ): Sendy, IronNet, StockX,
--     Bustle Digital Group, Clearco
----------------------------------------------------------------------

-- 4a. Preview: should show exactly 4 rows
SELECT *
FROM dbo.layoffs_staging
WHERE (company = 'Bybit' AND date = '6/20/2022'
       AND ISNULL(CAST(total_laid_off AS VARCHAR(20)), 'NULL') = 'NULL'
       AND ISNULL(CAST(percentage_laid_off AS VARCHAR(20)), 'NULL') = 'NULL')
   OR (company = 'Terminus' AND stage = 'Unknown')
   OR (company = 'Oda' AND TRY_CAST(funds_raised_millions AS FLOAT) IN (377, 479));
GO

-- 4b. Delete them
DELETE FROM dbo.layoffs_staging
WHERE (company = 'Bybit' AND date = '6/20/2022'
       AND ISNULL(CAST(total_laid_off AS VARCHAR(20)), 'NULL') = 'NULL'
       AND ISNULL(CAST(percentage_laid_off AS VARCHAR(20)), 'NULL') = 'NULL')
   OR (company = 'Terminus' AND stage = 'Unknown')
   OR (company = 'Oda' AND TRY_CAST(funds_raised_millions AS FLOAT) IN (377, 479));
GO

SELECT COUNT(*) AS rows_after_step4 
FROM dbo.layoffs_staging;   -- expect 2352
GO


----------------------------------------------------------------------
-- STEP 5: Turn the word 'NULL' (text) into real empty values
--   The import saved blanks as the text 'NULL'.
--   stage and date refused empty values, so allow them first.
----------------------------------------------------------------------

-- 5a. Before: how many cells hold the word 'NULL'? (expect 737 / 782 / 208)
SELECT
    SUM(CASE WHEN CAST(total_laid_off AS VARCHAR(20))        = 'NULL' THEN 1 ELSE 0 END) AS text_null_laid_off,
    SUM(CASE WHEN CAST(percentage_laid_off AS VARCHAR(20))   = 'NULL' THEN 1 ELSE 0 END) AS text_null_pct,
    SUM(CASE WHEN CAST(funds_raised_millions AS VARCHAR(20)) = 'NULL' THEN 1 ELSE 0 END) AS text_null_funds
FROM dbo.layoffs_staging;
GO

-- 5b. Allow empty values in stage and date
ALTER TABLE dbo.layoffs_staging ALTER COLUMN stage NVARCHAR(50) NULL;
ALTER TABLE dbo.layoffs_staging ALTER COLUMN date  NVARCHAR(50) NULL;
GO

-- 5c. Convert the word 'NULL' into real empty values
UPDATE dbo.layoffs_staging
SET industry              = NULLIF(industry, 'NULL'),
    stage                 = NULLIF(stage, 'NULL'),
    date                  = NULLIF(date, 'NULL'),
    total_laid_off        = NULLIF(total_laid_off, 'NULL'),
    percentage_laid_off   = NULLIF(percentage_laid_off, 'NULL'),
    funds_raised_millions = NULLIF(funds_raised_millions, 'NULL');
GO

-- 5d. After: real empty cells (expect 737 / 782 / 208 / 6 / 4)
SELECT
    SUM(CASE WHEN total_laid_off        IS NULL THEN 1 ELSE 0 END) AS empty_laid_off,
    SUM(CASE WHEN percentage_laid_off   IS NULL THEN 1 ELSE 0 END) AS empty_pct,
    SUM(CASE WHEN funds_raised_millions IS NULL THEN 1 ELSE 0 END) AS empty_funds,
    SUM(CASE WHEN stage                 IS NULL THEN 1 ELSE 0 END) AS empty_stage,
    SUM(CASE WHEN industry              IS NULL THEN 1 ELSE 0 END) AS empty_industry
FROM dbo.layoffs_staging;
GO


----------------------------------------------------------------------
-- STEP 6: Change the number columns from text to numbers
----------------------------------------------------------------------

-- 6a. Check first: expect 0 rows
SELECT total_laid_off, percentage_laid_off, funds_raised_millions
FROM dbo.layoffs_staging
WHERE (total_laid_off        IS NOT NULL AND TRY_CAST(total_laid_off AS INT)          IS NULL)
   OR (percentage_laid_off   IS NOT NULL AND TRY_CAST(percentage_laid_off AS FLOAT)   IS NULL)
   OR (funds_raised_millions IS NOT NULL AND TRY_CAST(funds_raised_millions AS FLOAT) IS NULL);
GO

-- 6b. Convert
ALTER TABLE dbo.layoffs_staging ALTER COLUMN total_laid_off        INT;
ALTER TABLE dbo.layoffs_staging ALTER COLUMN percentage_laid_off   FLOAT;
ALTER TABLE dbo.layoffs_staging ALTER COLUMN funds_raised_millions FLOAT;
GO


----------------------------------------------------------------------
-- STEP 7: Standardize labels
----------------------------------------------------------------------

-- 7a. Preview: expect 10 rows
SELECT industry, country, company
FROM dbo.layoffs_staging
WHERE industry IN ('Crypto Currency', 'CryptoCurrency', 'Fin-Tech')
   OR country = 'United States.';
GO

-- 7b. Fix them
UPDATE dbo.layoffs_staging
SET industry = 'Crypto'
WHERE industry IN ('Crypto Currency', 'CryptoCurrency');   -- expect 3

UPDATE dbo.layoffs_staging
SET industry = 'Finance'
WHERE industry = 'Fin-Tech';                               -- expect 3

UPDATE dbo.layoffs_staging
SET country = 'United States'
WHERE country = 'United States.';                          -- expect 4
GO

-- 7c. Trim extra spaces in company names (expect 0 rows: already clean)
UPDATE dbo.layoffs_staging
SET company = LTRIM(RTRIM(company))
WHERE DATALENGTH(company) <> DATALENGTH(LTRIM(RTRIM(company)));
GO

-- 7d. Check: no crypto variants, no Fin-Tech, one 'United States'
SELECT DISTINCT industry 
FROM dbo.layoffs_staging 
ORDER BY industry;

SELECT DISTINCT country  
FROM dbo.layoffs_staging 
ORDER BY country;
GO


----------------------------------------------------------------------
-- STEP 8: Convert date from text (month/day/year) to a real date
----------------------------------------------------------------------

-- 8a. Check first: expect 0 rows
SELECT date
FROM dbo.layoffs_staging
WHERE date IS NOT NULL AND TRY_CONVERT(date, date, 101) IS NULL;
GO

-- 8b. Rewrite as yyyy-mm-dd, then change the column type
UPDATE dbo.layoffs_staging
SET date = CONVERT(VARCHAR(10), TRY_CONVERT(date, date, 101), 23)
WHERE date IS NOT NULL;
GO

ALTER TABLE dbo.layoffs_staging ALTER COLUMN date DATE;
GO


----------------------------------------------------------------------
-- STEP 9: Final checks
----------------------------------------------------------------------

-- Row count: expect 2352
SELECT COUNT(*) AS final_rows FROM dbo.layoffs_staging;

-- Column types: date = date, total_laid_off = int, percentage/funds = float
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'layoffs_staging';

-- Date range: expect 2020-03-11 to 2023-03-06, 1 empty date
SELECT MIN(date) AS first_date, MAX(date) AS last_date,
       SUM(CASE WHEN date IS NULL THEN 1 ELSE 0 END) AS empty_dates
FROM dbo.layoffs_staging;

-- Rows missing headcount and/or percentage (expect 359 / 378 / 423)
-- These stay empty on purpose: no values are estimated.
SELECT
    SUM(CASE WHEN total_laid_off IS NULL     AND percentage_laid_off IS NULL     THEN 1 ELSE 0 END) AS both_missing,
    SUM(CASE WHEN total_laid_off IS NULL     AND percentage_laid_off IS NOT NULL THEN 1 ELSE 0 END) AS only_pct,
    SUM(CASE WHEN total_laid_off IS NOT NULL AND percentage_laid_off IS NULL     THEN 1 ELSE 0 END) AS only_count
FROM dbo.layoffs_staging;
GO


----------------------------------------------------------------------
-- ANALYSIS (cleaning is done; highlight ONE query at a time to run it)
----------------------------------------------------------------------

-- ANALYSIS 1: Layoffs by year
SELECT YEAR(date)           AS yr,
       COUNT(*)             AS layoff_events,
       SUM(total_laid_off)  AS people_laid_off
FROM dbo.layoffs_staging
WHERE date IS NOT NULL
GROUP BY YEAR(date)
ORDER BY yr;

-- ANALYSIS 2: Layoffs by month
SELECT YEAR(date)           AS yr,
       MONTH(date)          AS mth,
       COUNT(*)             AS layoff_events,
       SUM(total_laid_off)  AS people_laid_off
FROM dbo.layoffs_staging
WHERE date IS NOT NULL
GROUP BY YEAR(date), MONTH(date)
ORDER BY yr, mth;

-- ANALYSIS 3: Layoffs by funding stage

WITH s AS (
    SELECT ISNULL(stage, 'Unknown') AS stage,
           total_laid_off,
           percentage_laid_off
    FROM dbo.layoffs_staging
)
SELECT stage,
       COUNT(*)                                                 AS layoff_events,
       SUM(total_laid_off)                                      AS people_laid_off,
       ROUND(AVG(percentage_laid_off) * 100, 1)                 AS avg_pct_cut,
       SUM(CASE WHEN percentage_laid_off = 1 THEN 1 ELSE 0 END) AS shutdowns
FROM s
GROUP BY stage
ORDER BY CASE WHEN stage = 'Seed'        THEN 0
              WHEN stage LIKE 'Series %' THEN 1
              WHEN stage = 'Post-IPO'    THEN 2
              ELSE 3 END,
         stage;

-- ANALYSIS 4: Layoffs by industry
SELECT industry,
       COUNT(*)                                 AS layoff_events,
       SUM(total_laid_off)                      AS people_laid_off,
       ROUND(AVG(percentage_laid_off) * 100, 1) AS avg_pct_cut
FROM dbo.layoffs_staging
GROUP BY industry
ORDER BY people_laid_off DESC;

-- ANALYSIS 5: Shutdowns (100% cut) with the most funding raised
SELECT TOP 10
       company,
       stage,
       industry,
       date,
       total_laid_off,
       funds_raised_millions
FROM dbo.layoffs_staging
WHERE percentage_laid_off = 1
ORDER BY funds_raised_millions DESC;