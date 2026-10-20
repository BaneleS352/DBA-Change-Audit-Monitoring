/* Read-only. Run on the first target server in SSMS.
   Requires visibility of the DBA table metadata. No source SQL text is returned.
   An empty result may mean insufficient permissions rather than an absent object. */
USE [DBA];
GO
SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS SourceServer,
       SYSDATETIMEOFFSET() AS ServerTimeWithOffset,
       SYSUTCDATETIME() AS ObservedUtc;

SELECT c.column_id, c.name AS ColumnName, t.name AS DataType,
       c.max_length AS MaxLengthBytes, c.precision, c.scale,
       c.is_nullable, c.is_identity, c.is_computed,
       dc.definition AS DefaultDefinition
FROM sys.columns AS c
JOIN sys.types AS t ON t.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints AS dc ON dc.object_id = c.default_object_id
WHERE c.object_id = OBJECT_ID(N'dbo.__schema_change_tracking', N'U')
ORDER BY c.column_id;

SELECT i.name AS IndexName, i.is_unique, i.is_primary_key,
       i.type_desc, i.has_filter, i.filter_definition,
       c.name AS ColumnName, ic.key_ordinal, ic.is_descending_key,
       ic.is_included_column
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
  ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c
  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'dbo.__schema_change_tracking', N'U')
ORDER BY i.index_id, ic.index_column_id;
GO

/* Run separately in EACH monitored user database to inspect coverage:
SELECT DB_NAME() AS DatabaseName, t.name, t.is_disabled,
       e.type_desc AS EventType
FROM sys.triggers AS t
LEFT JOIN sys.trigger_events AS e ON e.object_id = t.object_id
WHERE t.parent_class = 0 AND t.name = N'schema_change_tracking'
ORDER BY e.type_desc;
*/





Ownpay                         qa-ownpay-ownpay
Merchants                      qa-ownpay-luckfish     &    qa-ownpay-hollywood
MerchantReporting              qa-ownpay-merchantreporting



Ownpay                         qa-ownpay-ownpaydb
Merchants                      qa-ownpay-luckfishdb     &    qa-ownpay-hollywooddb
MerchantReporting              qa-ownpay-merchantreportingdb