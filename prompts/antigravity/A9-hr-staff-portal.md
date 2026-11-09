# A9 · Human Resources and Staff Portal

SQL file: `supabase/sql/24_hr.sql`. HR data is the most sensitive: keep the existing rule (HR positions, or the employee's own record only).

## Build (SAP's 3 HR functions + the 6 new ones, kept per the decision of 9 Nov)
- **Employee master:** create and edit for HR, with documents (passport, visa, Emirates ID, labour card) stored in private Storage with expiry dates. Expiry alerts at 60, 30 and 7 days.
- **Staff Portal** (every employee, phone-first):
  - my profile, payslips, leave balance, requests
  - **attendance check-in and check-out** with the browser's location; outside the site area → flagged (rule "Check-in outside site area")
- **Duties and shifts** per department.
- **Leave:**
  - types from `leave_type`
  - request → manager approval → HR; long leave also needs Owner approval (design rule)
  - balance accrual
- **Payroll:** monthly run from `wage_type` and `employee_pay`, with overtime and deductions, then review, lock, and payroll results.
- **WPS file:** the UAE Wage Protection System SIF file per company and bank. Validate before export.
- **Air ticket accrual** and end-of-service gratuity per UAE labour law, calculated and shown, not posted until approved.
- Posting the payroll journal goes through A3.

## Privacy
- Salary fields are never sent to non-HR users, not even hidden in the UI.
- Signed URLs for documents last 10 minutes or less.
- Every view of a salary is audited.

## Tests
- An employee sees only their own record.
- A manager sees their team's leave only.
- Payroll maths for sample employees.
- WPS file passes format validation.
- Check-in outside the area is flagged.

## Needs from Ashif
The leave policy, overtime rules, the bank's WPS routing codes, the site coordinates and radius, and the gratuity policy.
