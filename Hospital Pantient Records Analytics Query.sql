--I. Date Prepared
	--1. Create Encounters View
CREATE VIEW vEncounters AS
SELECT
  TRIM(e.Id) AS EncounterId,
  TRY_CONVERT(datetimeoffset(0), TRIM(e.START), 127) AS Start_DT,
  TRY_CONVERT(datetimeoffset(0), TRIM(e.STOP), 127)  AS Stop_DT,
  TRY_CONVERT(date, TRIM(e.START), 127)              AS StartDate,
  DATEPART(YEAR, TRY_CONVERT(datetime2, TRIM(e.START), 127))     AS StartYear,
  DATEPART(QUARTER, TRY_CONVERT(datetime2, TRIM(e.START), 127))  AS StartQuarter,
  TRIM(e.PATIENT) AS PatientId,
  TRIM(e.ORGANIZATION) AS OrganizationId,
  TRIM(e.PAYER) AS PayerId,
  LOWER(TRIM(e.ENCOUNTERCLASS)) AS EncounterClass,
  TRIM(e.CODE) AS EncounterCode,
  TRIM(e.DESCRIPTION) AS EncounterDescription,
  TRY_CONVERT(decimal(18,2), REPLACE(TRIM(e.BASE_ENCOUNTER_COST),',',''))  AS BaseEncounterCost,
  TRY_CONVERT(decimal(18,2), REPLACE(TRIM(e.TOTAL_CLAIM_COST),',',''))     AS TotalClaimCost,
  TRY_CONVERT(decimal(18,2), REPLACE(TRIM(e.PAYER_COVERAGE),',',''))       AS PayerCoverage,
  TRIM(e.REASONCODE) AS ReasonCode,
  TRIM(e.REASONDESCRIPTION) AS ReasonDescription,
  CASE
    WHEN TRY_CONVERT(datetime2, TRIM(e.START), 127) IS NULL
      OR TRY_CONVERT(datetime2, TRIM(e.STOP),  127) IS NULL THEN NULL
    ELSE DATEDIFF(MINUTE,
         TRY_CONVERT(datetime2, TRIM(e.START), 127),
         TRY_CONVERT(datetime2, TRIM(e.STOP),  127))
  END AS DurationMinutes
FROM encounters AS e;
GO

	--2. Create Procedures View
CREATE VIEW vProcedures AS
SELECT
  TRY_CONVERT(datetime2, TRIM(p.START), 127) AS Start_DT,
  TRY_CONVERT(datetime2, TRIM(p.STOP),  127) AS Stop_DT,
  TRIM(p.PATIENT) AS PatientId,
  TRIM(p.ENCOUNTER) AS EncounterId,
  TRIM(p.CODE) AS ProcedureCode,
  TRIM(p.DESCRIPTION) AS ProcedureDescription,
  TRY_CONVERT(decimal(18,2), REPLACE(TRIM(p.BASE_COST),',','')) AS BaseCost,
  TRIM(p.REASONCODE) AS ReasonCode,
  TRIM(p.REASONDESCRIPTION) AS ReasonDescription
FROM Procedures AS p;
GO

	--3. Create Payers View
CREATE VIEW vPayers AS
SELECT TRIM(Id) AS PayerId, TRIM(NAME) AS PayerName FROM Payers;
GO

	--4. Create Age Band 
-- Materialize a helper view once (optional)
IF OBJECT_ID('vEncountersWithPatient') IS NOT NULL DROP VIEW vEncountersWithPatient;
GO
CREATE VIEW vEncountersWithPatient AS
SELECT
  ve.*,
  vp.Gender,
  vp.BirthDate,
  DATEDIFF(YEAR, vp.BirthDate, ve.StartDate)
    - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, vp.BirthDate, ve.StartDate), vp.BirthDate) > ve.StartDate THEN 1 ELSE 0 END
    AS AgeAtEncounter
FROM vEncounters AS ve
LEFT JOIN vPatients AS vp ON vp.Id = ve.PatientId;
GO


	--5. Create Patients View
CREATE VIEW vPatients AS
SELECT
    Id,
    -- Strip digits from names
    LTRIM(RTRIM(
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
        CONCAT(FIRST, ' ', LAST),
        '0',''),'1',''),'2',''),'3',''),'4',''),'5',''),'6',''),'7',''),'8',''),'9','')
    )) AS PatientNameClean,
    GENDER,
    BIRTHDATE,
    DEATHDATE
FROM Patients;
GO

	--6. Create Organizations View

CREATE VIEW vOrganizations AS
SELECT
  TRIM(Id)   AS OrganizationId,
  TRIM(NAME) AS OrgName,
  TRIM(CITY) AS City,
  TRIM(STATE) AS State,
  TRIM(ZIP)  AS Zip
FROM Organizations;
GO

--II. Key Insights
	--1. ENCOUNTERS OVERVIEW
		--1.1. How many total encounters occurred each year?
SELECT StartYear, COUNT(*) AS TotalEncounters
FROM dbo.vEncounters
WHERE StartYear IS NOT NULL
GROUP BY StartYear
ORDER BY StartYear;

		--1.2. Monthly encounter trend
SELECT
  DATEFROMPARTS(StartYear, MONTH(StartDate), 1) AS MonthStart,
  COUNT(*) AS EncounterCount,
  CAST(AVG(TotalClaimCost) AS DECIMAL(18,2)) AS AvgClaimCost
FROM dbo.vEncounters
WHERE StartYear IS NOT NULL
GROUP BY DATEFROMPARTS(StartYear, MONTH(StartDate), 1)
ORDER BY MonthStart;


		--1.3. Percentage of all encounters belonged to each encounter class
WITH yearly AS (
  SELECT StartYear, EncounterClass, COUNT(*) AS Count
  FROM dbo.vEncounters
  WHERE StartYear IS NOT NULL AND EncounterClass IS NOT NULL
  GROUP BY StartYear, EncounterClass
)
SELECT
  StartYear, EncounterClass, Count,
  CAST(100.0 * Count / SUM(Count) OVER (PARTITION BY StartYear) AS DECIMAL(5,2)) AS Percentage_Of_Year
FROM yearly
ORDER BY StartYear, Count DESC;

		--1.4. Percentage of encounters were over 24 hours versus under 24 hours
WITH duration AS (
  SELECT
    CASE
      WHEN DurationMinutes IS NULL THEN 'Unknown'
      WHEN DurationMinutes >= 1440 THEN '>=24h'
      ELSE '<24h'
    END AS Duration_Bucket
  FROM vEncounters
  WHERE StartYear IS NOT NULL
)
SELECT
  Duration_Bucket,
  COUNT(*) AS Encounters,
  CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS Percentage_Of_Total
FROM duration
GROUP BY Duration_Bucket
ORDER BY CASE Duration_Bucket WHEN '>=24h' THEN 1 WHEN '<24h' THEN 2 ELSE 3 END;

	--2. COVERAGE INSIGHTS
		--2.1. Zero payer coverage (count & %)
WITH base AS (
  SELECT CASE WHEN ISNULL(PayerCoverage, 0) = 0 THEN 1 ELSE 0 END AS Is_Zero_Coverage
  FROM vEncounters
  WHERE StartYear IS NOT NULL
)
SELECT
  SUM(Is_Zero_Coverage) AS Encounters_Zero_Coverage,
  COUNT(*) AS Total_Encounters,
  CAST(100.0 * SUM(Is_Zero_Coverage) / COUNT(*) AS DECIMAL(5,2)) AS Percentage_Zero_Coverage
FROM base;
		--2.2. Coverage gap over time (zero coverage rate by year)

SELECT
  StartYear,
  SUM(CASE WHEN ISNULL(PayerCoverage,0)=0 THEN 1 ELSE 0 END) AS ZeroCoverageEncounters,
  COUNT(*) AS TotalEncounters,
  CAST(100.0 * SUM(CASE WHEN ISNULL(PayerCoverage,0)=0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS ZeroCoveragePct
FROM dbo.vEncounters
WHERE StartYear IS NOT NULL
GROUP BY StartYear
ORDER BY StartYear;

		--2.3. Avg total claim cost by payer
SELECT
  COALESCE(vp.PayerName, 'Unknown') AS Payer_Name,
  CAST(AVG(ve.TotalClaimCost) AS DECIMAL(18,2)) AS Avg_Total_Claim_Cost,
  COUNT(*) AS Encounter_Count
FROM vEncounters AS ve
LEFT JOIN vPayers AS vp ON ve.PayerId = vp.PayerId
GROUP BY COALESCE(vp.PayerName, 'Unknown')
ORDER BY Avg_Total_Claim_Cost DESC;

	--3. PROCEDURES & CLINICAL INSIGHTS

		--3.1. Top 10 most frequent procedures & avg base cost
SELECT TOP (10)
  ProcedureCode, ProcedureDescription,
  COUNT(*) AS Times_Performed,
  CAST(AVG(BaseCost) AS DECIMAL(18,2)) AS Avg_Base_Cost
FROM vProcedures
GROUP BY ProcedureCode, ProcedureDescription
ORDER BY Times_Performed DESC, ProcedureCode;


		--3.2. Top 10 procedures by highest avg base cost (and how often)
SELECT TOP (10)
  ProcedureCode, ProcedureDescription,
  CAST(AVG(BaseCost) AS DECIMAL(18,2)) AS Avg_Base_Cost,
  COUNT(*) AS Times_Performed
FROM vProcedures
GROUP BY ProcedureCode, ProcedureDescription
HAVING AVG(BaseCost) IS NOT NULL
ORDER BY Avg_Base_Cost DESC;


	--4. PATIENT DEMOGRAPHICS
		--4.1. AGE DISTRIBUTION
SELECT
  CASE
    WHEN AgeAtEncounter IS NULL THEN 'Unknown'
    WHEN AgeAtEncounter <= 18 THEN '0-18'
    WHEN AgeAtEncounter <= 35 THEN '19-35'
    WHEN AgeAtEncounter <= 50 THEN '36-50'
    WHEN AgeAtEncounter <= 65 THEN '51-65'
    ELSE '66+'
  END AS AgeBand,
  COUNT(*) AS EncounterCount
FROM vEncountersWithPatient
GROUP BY
  CASE
    WHEN AgeAtEncounter IS NULL THEN 'Unknown'
    WHEN AgeAtEncounter <= 18 THEN '0-18'
    WHEN AgeAtEncounter <= 35 THEN '19-35'
    WHEN AgeAtEncounter <= 50 THEN '36-50'
    WHEN AgeAtEncounter <= 65 THEN '51-65'
    ELSE '66+'
  END
ORDER BY MIN(AgeAtEncounter);  
 

		--4.2. Gender split (encounters & average cost)
SELECT
  COALESCE(vp.GENDER,'Unknown') AS Gender,
  COUNT(ve.EncounterId) AS EncounterCount,
  CAST(AVG(ve.TotalClaimCost) AS DECIMAL(18,2)) AS AvgClaimCost
FROM vPatients AS vp 
LEFT JOIN vEncounters AS ve ON vp.Id = ve.PatientId
GROUP BY COALESCE(Gender,'Unknown')
ORDER BY EncounterCount DESC;

	--5. PATIENT BEHAVIOUR ANALYSIS
		--5.1. Unique patients admitted each quarter (inpatient)
SELECT
  ve.StartYear,
  ve.StartQuarter,
  COUNT(DISTINCT ve.PatientId) AS Unique_Patients_Admitted
FROM vEncounters AS ve
WHERE LOWER(ve.EncounterClass) = 'inpatient'
GROUP BY ve.StartYear, ve.StartQuarter
ORDER BY ve.StartYear, ve.StartQuarter;

		--5.2. How many patients were readmitted within 30 days?
WITH ip AS (
  SELECT
    ve.PatientId, 
	ve.Start_DT, 
	ve.Stop_DT, 
	ve.EncounterId,
    ROW_NUMBER() OVER (PARTITION BY ve.PatientId ORDER BY ve.Start_DT) AS rn
  FROM vEncounters AS ve
  WHERE LOWER(ve.EncounterClass) = 'inpatient'
),
lagged AS (
  SELECT ip.*,
         LAG(ip.Stop_DT) OVER (PARTITION BY ip.PatientId ORDER BY ip.rn) AS Prev_Stop_DT
  FROM ip
)
SELECT
  COUNT(*) AS Readmission_Count,
  COUNT(DISTINCT PatientId) AS Patients_With_Readmission
FROM lagged
WHERE Prev_Stop_DT IS NOT NULL
  AND DATEDIFF(DAY, Prev_Stop_DT, Start_DT) BETWEEN 1 AND 30;

		--5.3. Which patients had the most readmissions?
WITH ip AS (
  SELECT
    ve.PatientId, ve.Start_DT, ve.Stop_DT,
    ROW_NUMBER() OVER (PARTITION BY ve.PatientId ORDER BY ve.Start_DT) AS rn
  FROM vEncounters AS ve
  WHERE LOWER(ve.EncounterClass) = 'inpatient'
),
lagged AS (
  SELECT ip.*,
         LAG(ip.Stop_DT) OVER (PARTITION BY ip.PatientId ORDER BY ip.rn) AS Prev_Stop_DT
  FROM ip
),
flags AS (
  SELECT
    PatientId,
    CASE WHEN Prev_Stop_DT IS NOT NULL
              AND DATEDIFF(DAY, Prev_Stop_DT, Start_DT) BETWEEN 1 AND 30
         THEN 1 ELSE 0 END AS Is_Readmit_30d
  FROM lagged
)
SELECT TOP (10)
  f.PatientId,
	PatientNameClean,
  SUM(f.Is_Readmit_30d) AS Readmission_30d_Count
FROM flags f
LEFT JOIN vPatients AS p ON p.Id = f.PatientId
GROUP BY f.PatientId, PatientNameClean
ORDER BY Readmission_30d_Count DESC, f.PatientId;

	--6. GEOGRAPHIC
		--6.1. Encounters by organization & city/state
SELECT
  vo.State,
  vo.City,
  vo.OrgName,
  COUNT(*) AS Encounter_Count,
  CAST(AVG(ve.TotalClaimCost) AS DECIMAL(18,2)) AS Avg_Claim_Cost
FROM vEncounters AS ve
LEFT JOIN vOrganizations AS vo ON vo.OrganizationId = ve.OrganizationId
GROUP BY vo.State, vo.City, vo.OrgName
ORDER BY Encounter_Count DESC;

		--6.2. Cost variation by state
SELECT
  vo.State,
  COUNT(*) AS EncounterCount,
  CAST(AVG(ve.TotalClaimCost) AS DECIMAL(18,2)) AS AvgClaimCost
FROM dbo.vEncounters ve
LEFT JOIN dbo.vOrganizations vo ON vo.OrganizationId = ve.OrganizationId
GROUP BY vo.State
ORDER BY AvgClaimCost DESC;

--III. Visualisation 

	--1. Encounters Fact Table
SELECT
  EncounterId,
  Start_DT,
  Stop_DT,
  StartDate,
  StartYear,
  StartQuarter,
  DATEFROMPARTS(StartYear, MONTH(StartDate), 1) AS MonthStart,
  PatientId,
  OrganizationId,
  PayerId,
  EncounterClass,
  EncounterCode,
  EncounterDescription,
  BaseEncounterCost,
  TotalClaimCost,
  PayerCoverage,
  DurationMinutes
FROM vEncounters;

	--2. Procedures Fact Table
SELECT
  EncounterId,
  PatientId,
  Start_DT,
  Stop_DT,
  ProcedureCode,
  ProcedureDescription,
  BaseCost
FROM vProcedures;

	--3. Patients Dimension Table
SELECT
  Id,
  PatientNameClean,
  Gender,
  BirthDate,
  DeathDate
FROM vPatients;

	--4. Payers Dimension Table
SELECT
  PayerId,
  PayerName
FROM vPayers;

	--5. Organizations Dimension Table
SELECT
  OrganizationId,
  OrgName,
  City,
  State,
  Zip
FROM vOrganizations;

	--6. Readmissions Table (30-day inpatient)

IF OBJECT_ID('vReadmit30dInpatient') IS NOT NULL DROP VIEW vReadmit30dInpatient;
GO
CREATE VIEW vReadmit30dInpatient AS
WITH ip AS (
  SELECT
    ve.PatientId,
    ve.Start_DT,
    ve.Stop_DT,
    ROW_NUMBER() OVER (PARTITION BY ve.PatientId ORDER BY ve.Start_DT) AS rn
  FROM vEncounters AS ve
  WHERE LOWER(ve.EncounterClass) = 'inpatient'
),
lagged AS (
  SELECT
    ip.PatientId, ip.Start_DT, ip.Stop_DT,
    LAG(ip.Stop_DT) OVER (PARTITION BY ip.PatientId ORDER BY ip.rn) AS Prev_Stop_DT
  FROM ip
)
SELECT
  PatientId,
  Start_DT, Stop_DT,
  CASE WHEN Prev_Stop_DT IS NOT NULL AND DATEDIFF(DAY, Prev_Stop_DT, Start_DT) BETWEEN 1 AND 30 THEN 1 ELSE 0 END AS IsReadmit30d
FROM lagged;
GO


SELECT
  PatientId,
  Start_DT,
  Stop_DT,
  DATEPART(YEAR, Start_DT) AS StartYear,
  DATEPART(QUARTER, Start_DT) AS StartQuarter,
  DATEFROMPARTS(DATEPART(YEAR, Start_DT), DATEPART(MONTH, Start_DT), 1) AS MonthStart, IsReadmit30d
FROM vReadmit30dInpatient;








