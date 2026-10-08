/* Calendar + fee calculation tests (no user session needed). Any THROW fails the run. */
SET NOCOUNT ON;

-- Permit fees: base + rate per $1,000, clamped to min/max
IF (SELECT Fee FROM core.fn_PermitFee('BUILD_RES', 100000)) <> 1100.00 THROW 50100, 'FAIL: BUILD_RES $100k fee should be 1100.00', 1;
IF (SELECT Fee FROM core.fn_PermitFee('BUILD_RES', 1000))   <> 200.00  THROW 50100, 'FAIL: minimum fee not applied', 1;
IF (SELECT Fee FROM core.fn_PermitFee('SIGN', 1000000))     <> 750.00  THROW 50100, 'FAIL: maximum fee not applied', 1;
IF EXISTS (SELECT 1 FROM core.fn_PermitFee('NOPE', 1))                 THROW 50100, 'FAIL: unknown permit type returned a fee', 1;

-- Ontario holidays
IF (SELECT IsBusinessDay FROM core.Calendar WHERE CalendarDate = '2026-04-03') <> 0 THROW 50100, 'FAIL: Good Friday 2026 should be a holiday', 1;
IF (SELECT IsBusinessDay FROM core.Calendar WHERE CalendarDate = '2026-02-16') <> 0 THROW 50100, 'FAIL: Family Day 2026 should be a holiday', 1;
IF (SELECT IsBusinessDay FROM core.Calendar WHERE CalendarDate = '2026-10-12') <> 0 THROW 50100, 'FAIL: Thanksgiving 2026 should be a holiday', 1;
IF (SELECT IsBusinessDay FROM core.Calendar WHERE CalendarDate = '2026-10-13') <> 1 THROW 50100, 'FAIL: 2026-10-13 should be a business day', 1;

-- SLA maths: Friday + 1 business day skips the weekend AND Thanksgiving Monday
IF (SELECT ResultDate FROM core.fn_AddBusinessDays('2026-10-09', 1)) <> '2026-10-13' THROW 50100, 'FAIL: AddBusinessDays over long weekend', 1;
IF (SELECT BusinessDays FROM core.fn_BusinessDaysBetween('2026-10-05', '2026-10-16')) <> 8 THROW 50100, 'FAIL: BusinessDaysBetween', 1;

PRINT 'PASS T01_calendar_and_fees';
