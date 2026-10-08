# Interview talking points

Short answers you can give from this project, mapped to likely questions. Practise saying them out loud, and demo live where you can.

**"Tell me about a database you designed."**
A service request and permit system for a county. SQL Server with five schemas: operational data, security, the procedures the app calls, integration, and a reporting star schema. The org chart is a `hierarchyid` tree, categories are a recursive tree, and SLA dates come from a business-day calendar that knows Ontario's statutory holidays, including Good Friday computed from the Easter algorithm.

**"How would you secure an application's data?"**
In layers, so one mistake doesn't expose anything. The app's login can only execute procedures, with DENY on every table. Row-Level Security means a Roads supervisor physically cannot select a Waste request. Contact details are masked, and the only way to unmask them is a procedure that demands a reason and logs it. Screen permissions live in a table admins can edit, and they're checked in the UI *and* again inside the procedure. *(Demo: sign in as `sup.roads` versus `sup.transport` and show the different queues; reveal a phone number, then show it in the privacy audit.)*

**"Tell me about a performance problem you solved."**
Use your own numbers from `docs/performance-tuning.md`: the slow statement, what the plan showed, why the RLS columns had to be in the INCLUDE list, and the before/after reads and time. Mention that the fix went through the pipeline as a migration, not as a hotfix on production.

**"How do you move changes from development to production safely?"**
Versioned migrations that run once and repeatable scripts for procedures, all applied by one deploy script. CI deploys to a throwaway SQL Server, runs it a second time to prove it's idempotent, runs database tests for security and workflow, then deploys to Test automatically and to Production only after a reviewer approves.

**"What's your backup strategy?"**
Full weekly, differential daily, log every 15 minutes, all with CHECKSUM, so RPO is 15 minutes. And I've tested it: the restore script builds the chain from `msdb` history and restores to a point in time side-by-side, so you can copy back just the damaged rows. *(Show your drill log entry.)*

**"Have you integrated with SAP or another ERP?"**
Not SAP directly, but I built the integration the same way I'd approach SAP through a service interface. The message is built as XML by SQL Server, posted by a background worker under its own login, and every attempt is logged with request and response. The receiving side is idempotent on the source reference, so retries are safe. Failures retry automatically, then wait on an admin screen for a person.

**"How do you support non-technical users?"**
The clerk guide is written in plain language, task by task. Error pages give the user a reference code that matches a row in the error log, so a support call goes straight to the cause. Messages like "changed by someone else, reload and try again" tell people what to do, not just what went wrong.

**"How does this relate to MFIPPA?"**
Collection notice at registration, data minimisation in reporting (the warehouse holds no personal information), masking by default, purpose-logged access, and temporal tables for a full change history.

**Be honest about scope.** This is a portfolio project: the ERP is a mock, the fee schedule is illustrative, and it hasn't run at County scale. Say what you'd do next: Windows authentication / Entra ID for staff, SSRS subscriptions, an Always On availability group for HA, and moving secrets to a vault.
