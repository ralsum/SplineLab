# Email Triage Operating Spec

Goal: process email in hourly batches, starting from the oldest unprocessed hour, then switch to a steady hourly run on the hour. Keep the Inbox and Junk emptied for processed mail by moving messages into archive folders.

## Scope

- Process mail from **Inbox** and **Junk**.
- Skip any message already in a folder.
- Skip any message already marked as read.
- Do not delete mail.

## Core triage rule

- If triage says a message is **important** or needs action, move it to the **Important** folder and leave it **unread**.
- All other processed mail goes to the appropriate archive folder and is marked **read**.
- If the destination folder is unclear or conflicting, move the message to **Undecided** temporarily.

## Folder mapping

Map mail into the existing folder tree shown in the mailbox image. Initial target folders:

- Facebook
- Finance
- Important
- Medical
- Newsletter
- Personal
- Postoffice
- Receipt
- Security
- Shopping
- Travel
- Unknown
- Work
- Undecided

Notes:
- **Important** is a special destination for acted-upon mail and stays unread.
- **Undecided** is the temporary conflict bucket.
- Additional folders can be proposed later after a few runs.

## Triage guidance

Initial importance decision is conservative:

- Mark as **Important** when the message clearly needs a human action or follow-up.
- Otherwise archive normally into the best matching folder.
- Use **Undecided** when two folders compete or the correct archive folder is not clear.

## Hourly processing behavior

### Catch-up mode

1. Find the oldest hour of mail that still needs processing.
2. Process that hour only.
3. Pause **5 seconds**.
4. Continue with the next hour.
5. Repeat until caught up to the current time.

### Steady-state mode

- Once caught up and everything looks good, run the process **every hour on the hour**.

## Timezone

- Use **America/New_York** for scheduling and interpretation.
- The user said Eastern Standard Time; America/New_York is preferred so daylight saving time is handled correctly unless a fixed EST-only schedule is explicitly desired.

## Operational notes

- Process one hour at a time until the policy is validated.
- After validation, keep the 5-second pause between batches.
- Reevaluate and refine folder rules after a few runs.
- Keep an audit trail for each move.

## Current caveats

- The mailbox image shows yearly folders plus a 2026/01 sub-tree; the exact archive destinations for each category may need refinement after a few runs.
- If the archive rule and read/unread rule conflict for a message, the importance rule wins: Important stays unread, everything else is read.
