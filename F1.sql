WITH RuleData AS (
    SELECT 
        ShiftID, 
        [Pre Time Minutes] AS Pre_Time_Minutes, 
        [Post Time] AS Post_Time_Minutes, 
        RuleRelatedTo, 
        Org6
    FROM (
        SELECT RuleItemValue, RuleConfigAttrItemName, RuleRelatedTo, ShiftID, Org6 
        FROM TNA.Vw_RuleConfigData 
        WHERE RuleEndDate IS NULL AND RuleRelatedTo = 'Shift Properties'
    ) AS SourceTable
    PIVOT (
        MAX(RuleItemValue)
        FOR RuleConfigAttrItemName IN ([Pre Time Minutes], [Post Time])
    ) AS PivotTable
),
WorkingHrsRule AS (
    SELECT 
        ShiftID, 
        Org6, 
        RuleRelatedTo,
        STRING_AGG(CASE WHEN RuleConfigAttrItemName = 'From Minutes' THEN CAST(RuleItemValue AS VARCHAR) ELSE NULL END, ',') AS FromMinutes,
        STRING_AGG(CASE WHEN RuleConfigAttrItemName = 'To Minutes' THEN CAST(RuleItemValue AS VARCHAR) ELSE NULL END, ',') AS ToMin,
        STRING_AGG(CASE WHEN RuleConfigAttrItemName = 'Status' THEN RuleItemValue ELSE NULL END, ',') AS Status
    FROM TNA.Vw_RuleConfigData 
    WHERE RuleEndDate IS NULL AND RuleRelatedTo = 'Working Hrs'
    GROUP BY ShiftID, Org6, RuleRelatedTo
),
WorkingHrsSlab AS (
    SELECT 
        ShiftID, 
        Org6,
        SUBSTRING(FromMinutes, 1, CHARINDEX(',', FromMinutes) - 1) + ',' + SUBSTRING(ToMin, 1, CHARINDEX(',', ToMin) - 1) AS A,
        SUBSTRING(FromMinutes, CHARINDEX(',', FromMinutes) + 1, CHARINDEX(',', FromMinutes, CHARINDEX(',', FromMinutes) + 1) - CHARINDEX(',', FromMinutes) - 1) + ',' + 
            SUBSTRING(ToMin, CHARINDEX(',', ToMin) + 1, CHARINDEX(',', ToMin, CHARINDEX(',', ToMin) + 1) - CHARINDEX(',', ToMin) - 1) AS [HD],
        SUBSTRING(FromMinutes, CHARINDEX(',', FromMinutes, CHARINDEX(',', FromMinutes) + 1) + 1, LEN(FromMinutes)) + ',' + 
            SUBSTRING(ToMin, CHARINDEX(',', ToMin, CHARINDEX(',', ToMin) + 1) + 1, LEN(ToMin)) AS [P]
    FROM WorkingHrsRule
),
SingleSwipeRule AS (
    SELECT 
        A.ShiftId,
        B.RuleItemValue AS SingleSwipeStatus,
        A.Org6
    FROM TNA.Vw_RuleConfigData A 
    INNER JOIN (
        SELECT * 
        FROM TNA.Vw_RuleConfigData
        WHERE RuleRelatedTo = 'Single Swipe' AND RuleConfigAttrItemName = 'Status' AND RuleEndDate IS NULL
    ) B 
    ON A.RuleId = B.RuleId AND A.[LineNo] = B.[LineNo] AND (A.ShiftID = B.ShiftID OR A.ShiftID IS NULL) AND A.Org6 = B.Org6
    WHERE A.RuleRelatedTo = 'Single Swipe'
),
Rostering AS (
    SELECT Empcode, [AttMode], [Date], DiffIN, DiffOUT, RegIN, RegOut, TotalworkedMinutes, FromMin, ToMin, ShiftID 
    FROM TNA.Rostering 
    WHERE [Date] >=DATEADD(DD, -1, CONVERT(DATE, GETDATE())) AND [Date] <=DATEADD(DD, 1, CONVERT(DATE, GETDATE()))
	
),
AttRuleGroup AS (
    SELECT A.EmployeeCode, C.AttributeTypeUnitID 
    FROM EmployeeAttributeDetails A 
    INNER JOIN AttributeTypeMaster B ON A.attributeTypeID = B.AttributeTypeID 
    INNER JOIN AttributeTypeUnitMaster C ON A.AttributeTypeUnitID = C.AttributeTypeUnitID
    WHERE ToDate IS NULL AND AttributeTypeCode = 'Attendance Rule Group'
),
FinalRoster AS (
    SELECT 
        A.Empcode, 
        A.[Date], 
        A.ShiftID, 
		A.AttMode,
        COALESCE(C.Pre_Time_Minutes, 0) AS PreTime, 
        COALESCE(C.Post_Time_Minutes, 0) AS PostTime,
        CONVERT(VARCHAR, A.[Date], 23) + ' ' + CONVERT(VARCHAR, SH.InTime, 108) AS ShiftIn,
        CASE WHEN SH.DateCross = 1 THEN CONVERT(VARCHAR, A.[Date] + 1, 23) ELSE CONVERT(VARCHAR, A.[Date], 23) END + ' ' + CONVERT(VARCHAR, SH.OutTime, 108) AS ShiftOut,
        D.A, D.HD, D.P, E.SingleSwipeStatus
    FROM Rostering A
    INNER JOIN TNA.ShiftMst SH ON SH.ShiftId = A.ShiftID
    INNER JOIN AttRuleGroup B ON A.EmpCode = B.EmployeeCode
    LEFT JOIN RuleData C ON A.ShiftID = C.ShiftID AND B.AttributeTypeUnitID = C.Org6
    LEFT JOIN WorkingHrsSlab D ON A.ShiftID = D.ShiftID AND B.AttributeTypeUnitID = D.Org6
    LEFT JOIN SingleSwipeRule E ON A.ShiftID = E.ShiftID AND B.AttributeTypeUnitID = E.Org6
)

SELECT TOP 100
    re.ed_empcode AS EmpCode,
    re.ed_Salutation, 
    re.ed_firstname, 
    re.ed_MiddleName, 
    re.ed_lastname,
    re.ed_empid,
    re.ED_Status,
    se.ESM_EmpStatusDesc,
    gc_bool.IPCheckEnabled,
    gc_bool.LocationCheckEnabled,
    gc_bool.IPCheckEnabledOnMobile,
    gc_bool.PunchIn,
    gc_bool.PunchOut,
    (
        SELECT 
            f2.[Date], 
            f2.ShiftID, 
			f2.AttMode,
            DATEADD(MINUTE, -f2.PreTime, f2.ShiftIn) AS ShiftINWithPRE, 
            DATEADD(MINUTE, f2.PostTime, f2.ShiftOut) AS ShiftOutWithPost, 
            f2.ShiftIn, 
            f2.ShiftOut, 
            f2.A, 
            f2.HD, 
            f2.P, 
            f2.SingleSwipeStatus
        FROM FinalRoster f2
        WHERE f2.Empcode = re.ed_empcode
        FOR JSON PATH
    ) AS ShiftDetails,
    (
        SELECT 
            gg.LocationID,
            MIN(gg.georange) AS georange,
            MAX(CAST(gg.rangeinkm AS INT)) AS rangeinkm,
            MIN(gl.Latitude) AS Latitude,
            MIN(gl.Longitude) AS Longitude,
            MIN(gg.FromDate) AS FromDate,
            MIN(gg.ToDate) AS ToDate,
            MIN(gl.LocationAlias) AS LocationAlias
        FROM TNA.Rostering AS ro_loc
        INNER JOIN GeoConfig.EmployeesLocationMapping AS gg 
            ON ro_loc.EmpCode = gg.EmployeeCode
        INNER JOIN GeoConfig.GeoConfigurationLocationMst gl
            ON gg.LocationID = gl.ID
        WHERE ro_loc.EmpCode = re.ed_empcode
        GROUP BY gg.LocationID
        FOR JSON PATH
    ) AS LocationDetails,
    (
        SELECT 
            geoip.IPFrom,
            geoip.IPTo
        FROM GeoConfig.GeoConfigurationIPMaster geoip  
        WHERE geoip.GeoConfigurationID IN (
            SELECT DISTINCT gl_sub.ID
            FROM GeoConfig.GeoConfigurationLocationMst gl_sub
            INNER JOIN GeoConfig.EmployeesLocationMapping gg_sub
                ON gl_sub.ID = gg_sub.LocationID
            WHERE gg_sub.EmployeeCode = re.ed_empcode
        )
        FOR JSON PATH
    ) AS IPRange
FROM reqrec_employeedetails AS re
INNER JOIN dbo.SETUP_EMPLOYEESTATUSMST AS se 
    ON re.ED_Status = se.ESM_EmpStatusID
CROSS APPLY (
    SELECT 
        CASE WHEN MAX(CAST(gl.IPCheckEnabled AS INT)) = 1 THEN 'true' ELSE 'false' END AS IPCheckEnabled,
        CASE WHEN MAX(CAST(gl.LocationCheckEnabled AS INT)) = 1 THEN 'true' ELSE 'false' END AS LocationCheckEnabled,
        CASE WHEN MAX(CAST(gl.IPCheckEnabledOnMobile AS INT)) = 1 THEN 'true' ELSE 'false' END AS IPCheckEnabledOnMobile,
        CASE WHEN MAX(CAST(el.PunchIn AS INT)) = 1 THEN 'true' ELSE 'false' END AS PunchIn,
        CASE WHEN MAX(CAST(el.PunchOut AS INT)) = 1 THEN 'true' ELSE 'false' END AS PunchOut
    FROM GeoConfig.GeoConfigurationLocationMst gl
    INNER JOIN GeoConfig.EmployeesLocationMapping el 
        ON gl.ID = el.LocationId
    WHERE el.EmployeeCode = re.ed_empcode
) AS gc_bool
WHERE EXISTS (
    SELECT 1
    FROM TNA.Rostering AS ro
    WHERE ro.EmpCode = re.ed_empcode --and ro.EmpCode='3538'
)
ORDER BY re.ed_empcode;
