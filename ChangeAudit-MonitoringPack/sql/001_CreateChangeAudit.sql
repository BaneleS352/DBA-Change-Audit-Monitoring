/* Run manually on HSB-SENTRY-SQL. SQL Server 2016+; compatibility level >=130.
   Creates only central monitoring storage. Never run against the production source database. */
USE master;
GO
IF DB_ID(N'DBA_ChangeAudit') IS NULL CREATE DATABASE DBA_ChangeAudit;
GO
USE DBA_ChangeAudit;
GO
IF (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) < 130
    THROW 51000, 'DBA_ChangeAudit requires compatibility level 130 or higher.', 1;
GO
IF OBJECT_ID(N'dbo.AuditRun', N'U') IS NULL
CREATE TABLE dbo.AuditRun (
    RunId bigint IDENTITY PRIMARY KEY,
    StartedAtUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CompletedAtUtc datetime2(3) NULL,
    Status nvarchar(30) NOT NULL DEFAULT N'Running',
    HealthJson nvarchar(max) NULL,
    CONSTRAINT CK_AuditRun_Health CHECK(HealthJson IS NULL OR ISJSON(HealthJson)=1)
);
IF OBJECT_ID(N'dbo.SourceState', N'U') IS NULL
CREATE TABLE dbo.SourceState (
    ServerName nvarchar(128) NOT NULL,
    SourceGeneration uniqueidentifier NOT NULL,
    Fingerprint nvarchar(256) NOT NULL,
    NewCursor int NOT NULL DEFAULT 0,
    ReconcileCursor int NOT NULL DEFAULT 0,
    LastCollectedAtUtc datetime2(3) NULL,
    CONSTRAINT PK_SourceState PRIMARY KEY(ServerName, SourceGeneration)
);
IF OBJECT_ID(N'dbo.ChangeEvent', N'U') IS NULL
CREATE TABLE dbo.ChangeEvent (
    EventId bigint IDENTITY PRIMARY KEY,
    ServerName nvarchar(128) NOT NULL,
    SourceGeneration uniqueidentifier NOT NULL,
    LogId int NOT NULL,
    DatabaseName nvarchar(256) NOT NULL,
    SchemaName nvarchar(128) NULL,
    ObjectName nvarchar(256) NOT NULL,
    ObjectType nvarchar(50) NOT NULL,
    EventType nvarchar(50) NOT NULL,
    SqlCommand nvarchar(max) NOT NULL,
    LoginName nvarchar(256) NOT NULL,
    EventDateLocal datetime2(3) NOT NULL,
    EventAtUtc datetime2(3) NOT NULL,
    SourceHash char(64) NOT NULL,
    FirstCollectedAtUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ChangeEvent_Source UNIQUE(ServerName, SourceGeneration, LogId)
);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.ChangeEvent') AND name=N'IX_ChangeEvent_Time')
    CREATE INDEX IX_ChangeEvent_Time ON dbo.ChangeEvent(EventAtUtc, ServerName);
IF OBJECT_ID(N'dbo.EvidenceSnapshot', N'U') IS NULL
CREATE TABLE dbo.EvidenceSnapshot (
    SnapshotId bigint IDENTITY PRIMARY KEY,
    RunId bigint NOT NULL REFERENCES dbo.AuditRun(RunId),
    EvidenceJson nvarchar(max) NOT NULL CHECK(ISJSON(EvidenceJson)=1),
    CapturedAtUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
IF OBJECT_ID(N'dbo.Assessment', N'U') IS NULL
CREATE TABLE dbo.Assessment (
    AssessmentId bigint IDENTITY PRIMARY KEY,
    RunId bigint NOT NULL REFERENCES dbo.AuditRun(RunId),
    EventId bigint NOT NULL REFERENCES dbo.ChangeEvent(EventId),
    RepositoryStatus nvarchar(40) NOT NULL,
    RabStatus nvarchar(40) NOT NULL,
    OverallStatus nvarchar(40) NOT NULL,
    EvidenceJson nvarchar(max) NOT NULL CHECK(ISJSON(EvidenceJson)=1),
    AssessedAtUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Assessment_RunEvent UNIQUE(RunId, EventId)
);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.Assessment') AND name=N'IX_Assessment_Latest')
    CREATE INDEX IX_Assessment_Latest ON dbo.Assessment(EventId, AssessmentId DESC);
GO
CREATE OR ALTER PROCEDURE dbo.usp_BeginRun AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.AuditRun DEFAULT VALUES;
    SELECT CAST(SCOPE_IDENTITY() AS bigint) AS RunId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_ReadState
    @ServerName nvarchar(128), @SourceGeneration uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM dbo.SourceState WHERE ServerName=@ServerName AND SourceGeneration=@SourceGeneration;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_StoreSourceBatch
    @ServerName nvarchar(128), @SourceGeneration uniqueidentifier,
    @Fingerprint nvarchar(256), @NewCursor int, @ReconcileCursor int, @EventsJson nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF ISJSON(@EventsJson)<>1 THROW 51000, 'Invalid event batch.', 1;
    DECLARE @Rows TABLE(LogId int, DatabaseName nvarchar(256), SchemaName nvarchar(128), ObjectName nvarchar(256),
        ObjectType nvarchar(50), EventType nvarchar(50), SqlCommand nvarchar(max), LoginName nvarchar(256),
        EventDateLocal datetime2(3), EventAtUtc datetime2(3), SourceHash char(64));
    INSERT @Rows SELECT * FROM OPENJSON(@EventsJson) WITH(
        LogId int, DatabaseName nvarchar(256), SchemaName nvarchar(128), ObjectName nvarchar(256),
        ObjectType nvarchar(50), EventType nvarchar(50), SqlCommand nvarchar(max), LoginName nvarchar(256),
        EventDateLocal datetime2(3), EventAtUtc datetime2(3), SourceHash char(64));
    IF EXISTS(SELECT LogId FROM @Rows GROUP BY LogId HAVING COUNT(*)>1)
        THROW 51000, 'Duplicate source IDs in batch. Source uniqueness must be investigated.', 1;
    BEGIN TRANSACTION;
    BEGIN TRY
        IF EXISTS(SELECT 1 FROM dbo.SourceState WITH(UPDLOCK,HOLDLOCK)
            WHERE ServerName=@ServerName AND SourceGeneration=@SourceGeneration AND Fingerprint<>@Fingerprint)
            THROW 51000, 'Source incarnation changed. Review and explicitly assign a new generation.', 1;
        IF EXISTS(SELECT 1 FROM dbo.ChangeEvent e JOIN @Rows r ON r.LogId=e.LogId
            WHERE e.ServerName=@ServerName AND e.SourceGeneration=@SourceGeneration AND e.SourceHash<>r.SourceHash)
            THROW 51000, 'Source ID reused or source evidence modified. Existing evidence preserved.', 1;
        INSERT dbo.ChangeEvent(ServerName,SourceGeneration,LogId,DatabaseName,SchemaName,ObjectName,ObjectType,EventType,SqlCommand,LoginName,EventDateLocal,EventAtUtc,SourceHash)
        SELECT @ServerName,@SourceGeneration,r.* FROM @Rows r
        WHERE NOT EXISTS(SELECT 1 FROM dbo.ChangeEvent e WITH(UPDLOCK,HOLDLOCK)
            WHERE e.ServerName=@ServerName AND e.SourceGeneration=@SourceGeneration AND e.LogId=r.LogId);
        IF NOT EXISTS(SELECT 1 FROM dbo.SourceState WITH(UPDLOCK,HOLDLOCK) WHERE ServerName=@ServerName AND SourceGeneration=@SourceGeneration)
            INSERT dbo.SourceState(ServerName,SourceGeneration,Fingerprint) VALUES(@ServerName,@SourceGeneration,@Fingerprint);
        UPDATE dbo.SourceState SET NewCursor=@NewCursor, ReconcileCursor=@ReconcileCursor, LastCollectedAtUtc=SYSUTCDATETIME()
        WHERE ServerName=@ServerName AND SourceGeneration=@SourceGeneration;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK;
        THROW;
    END CATCH
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_ReadToday
    @StartUtc datetime2(3), @EndUtc datetime2(3), @Limit int=10000
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP(@Limit) * FROM dbo.ChangeEvent
    WHERE EventAtUtc>=@StartUtc AND EventAtUtc<@EndUtc ORDER BY EventAtUtc, EventId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CompleteRun
    @RunId bigint, @Status nvarchar(30), @HealthJson nvarchar(max),
    @AssessmentsJson nvarchar(max), @EvidenceJson nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT dbo.EvidenceSnapshot(RunId,EvidenceJson) VALUES(@RunId,@EvidenceJson);
        INSERT dbo.Assessment(RunId,EventId,RepositoryStatus,RabStatus,OverallStatus,EvidenceJson)
        SELECT @RunId,EventId,RepositoryStatus,RabStatus,OverallStatus,EvidenceJson
        FROM OPENJSON(@AssessmentsJson) WITH(EventId bigint, RepositoryStatus nvarchar(40), RabStatus nvarchar(40),
            OverallStatus nvarchar(40), EvidenceJson nvarchar(max) AS JSON);
        UPDATE dbo.AuditRun SET Status=@Status, HealthJson=@HealthJson, CompletedAtUtc=SYSUTCDATETIME() WHERE RunId=@RunId;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK;
        THROW;
    END CATCH
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_DashboardJson AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Date date=CONVERT(date,DATEADD(hour,2,SYSUTCDATETIME()));
    DECLARE @Start datetime2=DATEADD(hour,-2,CONVERT(datetime2,@Date));
    SELECT (
        SELECT 1 AS schemaVersion, CONVERT(varchar(10),@Date,23) AS displayDate,
            CONVERT(varchar(33),SYSUTCDATETIME(),126)+'Z' AS generatedAtUtc,
            N'HSB-SYX20-SQL01' AS sourceServer,
            JSON_QUERY((SELECT TOP(1) RunId,Status,StartedAtUtc,CompletedAtUtc,JSON_QUERY(HealthJson) AS health
                FROM dbo.AuditRun ORDER BY RunId DESC FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS latestRun,
            (SELECT COUNT_BIG(*) FROM dbo.ChangeEvent WHERE EventAtUtc>=@Start AND EventAtUtc<DATEADD(day,1,@Start)) AS totalToday,
            JSON_QUERY((SELECT TOP(10000) e.EventId,e.LogId,e.ServerName,e.DatabaseName,e.SchemaName,e.ObjectName,e.EventType,e.LoginName,
                CONVERT(varchar(33),e.EventAtUtc,126)+'Z' AS eventAtUtc,
                ISNULL(a.RepositoryStatus,N'NotAssessed') AS repositoryStatus, ISNULL(a.RabStatus,N'NotAssessed') AS rabStatus,
                ISNULL(a.OverallStatus,N'NeedsReview') AS overallStatus,
                JSON_QUERY(a.EvidenceJson) AS evidence, e.SqlCommand AS sqlCommand
                FROM dbo.ChangeEvent e
                OUTER APPLY(SELECT TOP(1) * FROM dbo.Assessment a WHERE a.EventId=e.EventId ORDER BY a.AssessmentId DESC) a
                WHERE e.EventAtUtc>=@Start AND e.EventAtUtc<DATEADD(day,1,@Start)
                ORDER BY e.EventAtUtc DESC,e.EventId DESC FOR JSON PATH)) AS events
        FOR JSON PATH,WITHOUT_ARRAY_WRAPPER
    ) AS DashboardJson;
END;
GO
/* Least-privilege CENTRAL permissions; create the login separately if it does not exist. */
IF SUSER_ID(N'HOLLYWOODBETS\SentryOne') IS NOT NULL
BEGIN
    IF USER_ID(N'HOLLYWOODBETS\SentryOne') IS NULL CREATE USER [HOLLYWOODBETS\SentryOne] FOR LOGIN [HOLLYWOODBETS\SentryOne];
    GRANT EXECUTE ON dbo.usp_BeginRun TO [HOLLYWOODBETS\SentryOne];
    GRANT EXECUTE ON dbo.usp_ReadState TO [HOLLYWOODBETS\SentryOne];
    GRANT EXECUTE ON dbo.usp_StoreSourceBatch TO [HOLLYWOODBETS\SentryOne];
    GRANT EXECUTE ON dbo.usp_ReadToday TO [HOLLYWOODBETS\SentryOne];
    GRANT EXECUTE ON dbo.usp_CompleteRun TO [HOLLYWOODBETS\SentryOne];
    GRANT EXECUTE ON dbo.usp_DashboardJson TO [HOLLYWOODBETS\SentryOne];
END;
GO
