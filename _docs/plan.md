# Personal Productivity System — Product Requirements Document (PRD)

**Status:** Ready for v1 implementation  
**Primary inspiration:** Tina Huang’s productivity system  
**Vault name:** `Personal Productivity`  
**Suggested filesystem folder:** `Personal-Productivity`  
**Primary user:** Single user  
**Primary goal:** Increase deep work, finish important personal tasks, and make better use of flexible free time while preserving exercise/movement.

---

## 1. Product Summary

Build a personal productivity system from the ground up consisting of:

1. A dedicated Obsidian vault that acts as the source of truth.
2. A lightweight desktop task + Pomodoro application.
3. A Hermes-based Lifebot that reads the vault and provides recommendations.
4. Apple Health / Apple Watch context for movement and workout awareness.

The system is intentionally minimal. The desktop app is **not** an AI planner, analytics dashboard, or health app. It exists only to:

- create and manage tasks and subtasks,
- capture task metadata,
- run focus sessions,
- run optional breaks,
- log session outcomes into the Obsidian vault.

The Lifebot is responsible for reasoning, task recommendations, productivity analysis, and health-related nudges.

---

# 2. Goals

The system should help the user:

- get more deep work done,
- finish important personal projects and learning tasks,
- make better use of flexible time,
- avoid losing momentum after breaks,
- understand when different kinds of work are most effective,
- choose the best next focus session,
- avoid repeatedly sacrificing workouts and movement for deep work.

The system is for **personal projects and learning only**.

The user has a day job, but work-task management is out of scope.

---

# 3. Product Principles

## 3.1 Obsidian is the source of truth

The desktop application should not maintain an independent canonical database.

All durable productivity data should ultimately be stored in the dedicated Obsidian vault in machine-readable Markdown/YAML.

The user will provide the vault location to the coding agent during setup.

## 3.2 The app captures; Lifebot reasons

The desktop app should remain deliberately simple.

### Desktop app responsibilities

- task CRUD,
- subtask CRUD,
- metadata editing,
- project grouping,
- task status management,
- manual task ordering,
- focus timer,
- pause/resume/end,
- break timer,
- end-of-session logging.

### Lifebot responsibilities

- choosing the best next session,
- sequencing suggestions,
- productivity pattern analysis,
- historical behavioral analysis,
- health-context interpretation,
- Apple Health integration,
- exercise nudges,
- explanations for recommendations.

## 3.3 The user retains control

The bot should not automatically populate or schedule the day.

The user can ask:

> What should I do next?

Lifebot then selects the best **single next session** from the eligible backlog based on context.

## 3.4 Optimize from personal history, not generic productivity rules

Like Tina’s system, recommendations should increasingly rely on the user’s own history.

Examples:

- most effective time of day for a category,
- session completion patterns,
- preferred session lengths,
- effect of breaks,
- focus level by task type,
- energy level by time,
- likelihood of returning after a break,
- relationship between task effort and productive time,
- relationship between movement/workouts and later focus.

---

# 4. System Architecture

```text
Desktop Task + Focus App
        |
        | read/write
        v
Obsidian Vault: Personal Productivity
        ^
        |
        | read/analyze
        |
Hermes Lifebot
        |
        +---- Apple Health / Apple Watch
        |
        +---- User chat interaction
```

The task app and Lifebot should share data through the vault rather than tightly coupling their internal logic.

---

# 5. Obsidian Vault

## 5.1 Vault

Display name:

`Personal Productivity`

Suggested folder name:

`Personal-Productivity`

The system must support the vault being located anywhere on the user’s machine.

The path must be configurable.

## 5.2 Proposed structure

```text
Personal Productivity/
├── Tasks/
│   ├── <task>.md
│   └── ...
├── Logs/
│   ├── 2026-09-10.md
│   ├── 2026-09-11.md
│   └── ...
├── Health/
│   └── ...
├── Lifebot/
│   └── ...
└── .app/
    └── optional app configuration
```

The exact internal support-folder names may be adjusted during implementation, but the conceptual separation should remain.

## 5.3 Task storage

Use **one Markdown file per top-level task**.

Projects should **not** be represented as folders.

Project membership should be metadata.

Each task and subtask should have a stable unique internal ID.

Use UUIDs or an equivalent collision-safe identifier.

IDs are an implementation detail and should not normally be shown in the UI.

## 5.4 Subtask storage

Subtasks are embedded inside the parent task Markdown file.

Subtasks may contain nested subtasks recursively.

All nested subtasks inherit:

- project,
- categories.

They have their own:

- ID,
- title,
- status,
- priority,
- effort,
- deadline,
- notes,
- focus-session history by reference.

## 5.5 Session storage

Focus sessions should be stored in daily log files rather than one file per session.

Example:

```text
Logs/2026-09-10.md
```

A session should link to the task/subtask using its internal `task_id`.

The app and Lifebot resolve the ID to the current human-readable task title.

Do not rely on task title as the primary relationship key.

---

# 6. Task Model

## 6.1 Required task fields

Every task must include:

- title,
- category/categories,
- status.

A task may belong to zero or one project.

## 6.2 Optional task fields

- project,
- priority,
- estimated effort,
- deadline,
- notes.

## 6.3 Categories

Categories are user-created labels.

Requirements:

- at least one category is required when creating a task,
- multiple categories are allowed,
- the task form should allow selecting an existing category,
- the task form should allow creating a new category inline.

Categories are primarily labels for organization, but the stored metadata should be available to Lifebot for analysis.

## 6.4 Projects

Projects are simple containers.

Projects do not require:

- descriptions,
- goals,
- statuses,
- separate project-management workflows.

Tasks may exist without a project.

## 6.5 Status

Allowed statuses:

- `To Do`
- `In Progress`
- `Blocked`
- `Dropped`
- `Done`

Behavior:

- starting a focus session on a `To Do` task automatically moves it to `In Progress`,
- creating an ad-hoc task from the timer and starting it sets it to `In Progress`,
- `Blocked` tasks must be manually unblocked before starting a focus session,
- `Dropped` tasks should not appear in Lifebot planning unless manually restored,
- `Blocked` tasks should not appear in Lifebot planning,
- choosing “Completed task: Yes” at session completion sets the linked task/subtask to `Done`,
- if all children of a parent task are `Done`, the parent automatically becomes `Done`,
- recursive completion should bubble upward through nested subtasks.

## 6.6 Priority

Optional values:

- Low
- Medium
- High

## 6.7 Estimated effort

Optional values:

- S
- M
- L
- XL

This should be treated as an ordinal planning signal rather than a fixed number of minutes.

## 6.8 Deadlines

Optional date field.

The app does not independently schedule tasks from deadlines.

Lifebot may use deadlines when recommending the next session.

---

# 7. Task Hierarchy

Top-level tasks may contain subtasks.

Subtasks may contain additional nested subtasks.

Each task/subtask:

- has its own unique ID,
- can have its own status,
- can have its own priority,
- can have its own effort,
- can have its own deadline,
- can have its own notes,
- can receive its own Pomodoro sessions.

Subtasks inherit project and categories from the parent hierarchy.

---

# 8. Task App

## 8.1 Purpose

The app is a minimal productivity capture interface.

It should not become a full project-management system.

Core jobs:

1. Create/edit tasks and subtasks.
2. Browse tasks.
3. Start a focus session.
4. Run the timer.
5. Log the result.
6. Optionally run a break.

## 8.2 Default view

The full app opens to the **Tasks** view.

## 8.3 Task organization

Tasks are displayed in **separate collapsible sections for each project**.

Tasks with no project appear in a collapsible:

`No Project`

section at the **bottom**.

Within each project:

- tasks are grouped by status,
- status groups may be collapsible,
- active groups are primarily:
  - To Do
  - In Progress
  - Blocked

`Done` and `Dropped` are hidden by default and available through filtering/expansion.

## 8.4 Ordering

The app does not algorithmically rank tasks.

Within a status group, the user can manually drag-and-drop tasks to reorder them.

The task UI is an inventory and execution interface.

Lifebot decides what task is optimal when asked.

## 8.5 Creating a task

The normal create-task form should capture all task properties at creation time.

Required:

- title,
- at least one category,
- status.

Optional:

- project,
- priority,
- effort,
- deadline,
- notes.

All properties can be edited later.

## 8.6 Ad-hoc task creation

When starting a focus session, the user must either:

- select an existing task/subtask, or
- create a new ad-hoc task.

Ad-hoc task creation requires immediately:

- title,
- at least one category.

The new task is saved into the normal task inventory.

The user can later add or change:

- project,
- categories,
- priority,
- effort,
- deadline,
- notes,
- subtasks.

When its first session starts, it becomes `In Progress`.

---

# 9. Focus Timer

## 9.1 Session-task relationship

One focus session links to exactly **one** task or subtask.

If the task is completed before the timer expires, the user can end the session and mark the task completed.

## 9.2 Duration

Session duration is configurable per session.

Default:

`25 minutes`

The user can change the duration before starting.

Do not require fixed preset buttons.

## 9.3 Session controls

During a running session:

- Pause
- Resume
- End Session

Pausing should not end the session.

Paused time must be excluded from focused duration.

## 9.4 Pause telemetry

The system should log:

- pause count,
- total paused duration.

Exact individual pause intervals may be stored if convenient for implementation, but the UI only requires aggregate pause information.

## 9.5 Ending a session

Pressing `End Session` should show a minimal confirmation:

- End
- Cancel

Confirming End opens the end-of-session modal.

There is no separate user-facing classification such as:

- stopped early,
- abandoned,
- completed normally.

Actual session data is sufficient.

---

# 10. Full Timer UI

Use the Microsoft Clock Focus Session visual language shown by the user as the design reference.

## 10.1 Visual hierarchy

The full-screen timer should include:

- task title,
- project,
- categories,
- current session number for that task today,
- large circular countdown,
- circular progress ring that shrinks as time passes,
- estimated finish time under the ring,
- Pause / Resume control,
- End Session control.

Do not show:

- elapsed time,
- progress percentage,
- priority,
- effort,
- deadline,
- analytics,
- next-task suggestions.

The timer should visually prioritize the countdown.

## 10.2 Navigation behavior

Starting a session automatically switches the full app into the Timer view.

The user can then collapse it into mini mode.

---

# 11. Mini Timer UI

Mini mode is inspired by Microsoft Clock’s compact always-on-top mode.

While a focus session is active, mini mode should:

- stay always on top by default,
- show task title,
- show countdown,
- show current session number for that task today,
- show Pause/Resume,
- show End/Stop.

Do not show:

- project,
- categories,
- metadata,
- ETA,
- next-task suggestions,
- analytics.

---

# 12. End-of-Session Modal

When a focus session ends, show a modal over the timer.

The modal must include:

## 12.1 Task completion

`Completed task?`

Buttons:

- Yes
- No

Behavior:

- Yes → linked task/subtask becomes `Done`,
- No → task remains `In Progress`.

If completing a child causes all children of its parent to be `Done`, automatically complete the parent.

## 12.2 Focus level

1–5 selectable buttons.

## 12.3 Energy level

1–5 selectable buttons.

## 12.4 Notes

Free-text field.

No structured prompt is required.

## 12.5 Submission

The form must be completed before another work session can begin.

After submission, return the user to the main app/task list.

---

# 13. Focus Session Logging

Each completed focus-session log should contain enough information for Lifebot to analyze behavior over time.

At minimum:

```yaml
session_id:
task_id:
started_at:
ended_at:
focused_duration:
pause_count:
paused_duration:
focus_rating:
energy_rating:
task_completed:
notes:
```

`focused_duration` excludes paused time.

Session logs should not duplicate task metadata unnecessarily.

Project/categories can be resolved through `task_id`.

---

# 14. Breaks

## 14.1 Break behavior

Breaks do not automatically start after a Pomodoro.

After completing the end-of-session form, the user may choose:

- Start Next Session
- Take Break

## 14.2 Break timer

If `Take Break` is selected:

- show a break timer,
- default duration is 5 minutes,
- duration is configurable before starting.

## 14.3 End of break

When the break timer ends:

- notify the user in the app,
- do not automatically start the next focus session,
- provide a path back to selecting the next task/session.

This is necessary because the next focus session requires selecting a task.

## 14.4 Break logging

Log the actual timed break duration.

Do not separately track “overrun time” after the timer expires.

Energy and focus ratings are collected only after work sessions, not breaks.

---

# 15. Lifebot

## 15.1 Platform

Implement as a Hermes-based agent.

It reads the Obsidian vault as the productivity memory/data source.

The desktop app should not embed Lifebot reasoning directly.

## 15.2 Core interaction model

The user remains responsible for deciding what belongs in the backlog.

Lifebot does not automatically assign tasks.

The primary decision-support query is:

> What should I do next?

Lifebot should respond with the **best single next focus session**.

## 15.3 Recommendation inputs

When choosing the next session, Lifebot should balance:

- priority,
- deadline,
- task effort,
- current time,
- remaining free-time window,
- current energy,
- time already spent working today,
- historical performance by time of day,
- historical performance by category,
- historical session-length patterns,
- previous completion behavior,
- break/continuation patterns,
- available health context.

## 15.4 Free-time input

When asking Lifebot to plan or recommend a next session, the user should be able to provide one or more specific free-time windows.

Example:

```text
09:00–12:00
14:00–17:00
```

Lifebot should ensure its recommendation fits the remaining available window.

## 15.5 Energy input

Before planning or recommending sessions, Lifebot may ask the user for a current energy score.

Use:

`1–5`

Historical end-of-session energy ratings should also be used.

## 15.6 Output

The normal recommendation should be concise.

Example structure:

```text
Next session: Build task logger
Recommended duration: 40 min

Why: High priority, fits your remaining window, and you usually perform well on coding tasks at this time.
```

The explanation should be short and practical.

## 15.7 Session-length recommendation

Lifebot should recommend a focus-session length when selecting the next task.

The recommendation can use:

- remaining free time,
- task effort,
- historical completion behavior,
- time of day,
- current energy,
- historical session lengths.

---

# 16. Health Context

Health integration belongs to Lifebot, **not the desktop task app**.

## 16.1 v1 health data

Use:

- Apple Health steps,
- Apple Watch workouts.

Do not include sleep in v1.

## 16.2 Purpose

Health information is primarily contextual data for reasoning and historical analysis.

Lifebot may learn relationships such as:

- whether movement improves later focus,
- whether workouts affect continuation,
- whether long work sessions crowd out exercise,
- which times the user tends to skip movement,
- patterns in exercise override reasons.

## 16.3 After-5pm exercise rule

When the user attempts to start another focus session **after 5:00 PM**, Lifebot should check the latest health context.

Trigger the health warning only when **both** are true:

1. steps < 4,000,
2. no workout of at least 15 minutes has been recorded that day.

If both conditions are true:

- Lifebot should strongly recommend going out / exercising instead,
- the desktop app should surface the warning before the timer can start,
- the timer should be blocked until the user responds.

The user may override.

## 16.4 Override

To override the health warning:

- user must explicitly choose to continue,
- user must enter a free-text reason.

The override reason should be stored so Lifebot can later analyze patterns in why exercise was skipped.

## 16.5 Health data freshness

Do not make Apple Health management a visible part of the task app.

Health synchronization is a Lifebot concern.

Periodic or context-triggered synchronization is acceptable.

The exact transport/sync implementation may be chosen by the coding agent.

---

# 17. Analytics Lifebot Should Eventually Support

The system should capture data that allows questions such as:

- When am I most effective at deep work?
- What time of day is best for coding?
- What time is best for reading or learning?
- Which categories have the best completion rates?
- Which categories are hardest to resume after a break?
- What session length tends to work best?
- When does my focus quality decline?
- How does current energy affect completion?
- How much deep work do I usually complete before stopping for the day?
- Which kinds of breaks cause me not to return?
- Does exercise improve later focus?
- How often do I override the exercise warning?
- What reasons do I give when I skip exercise?
- Which task sizes work best at different times of day?
- How much productive work can I realistically fit into a remaining window?

This analytics layer does not need a dedicated dashboard in v1.

Lifebot can answer these conversationally.

---

# 18. Data Integrity Requirements

The implementation should prioritize reliable data relationships.

Requirements:

- stable internal IDs,
- session → task relationship via ID,
- rename-safe references,
- automatic parent completion,
- no duplicated task state across independent app databases,
- atomic or safely recoverable file writes,
- valid Markdown/YAML after every update,
- graceful handling if the vault is temporarily unavailable,
- no silent loss of session data.

---

# 19. v1 Non-Goals

Do **not** build these unless needed later:

- work/day-job task management,
- team collaboration,
- cloud accounts,
- social features,
- multi-user support,
- recurring tasks,
- complex project management,
- project goals/statuses,
- Gantt charts,
- calendar scheduling UI,
- automatic AI scheduling,
- AI task generation,
- productivity dashboards,
- manual health-entry UI,
- sleep tracking,
- HRV analysis,
- notifications for every idle period,
- forced exercise blocking,
- multiple tasks in one focus session,
- automatic next-session start,
- automatic break start,
- fixed Pomodoro presets,
- generic habit tracker.

---

# 20. Suggested Core User Flows

## 20.1 Create task

```text
Tasks
→ New Task
→ Title
→ Category(s)
→ Status
→ Optional project / priority / effort / deadline / notes
→ Save
```

## 20.2 Create subtask

```text
Task
→ Add Subtask
→ Title
→ Status
→ Optional priority / effort / deadline / notes
→ Save
```

Project and categories inherit automatically.

## 20.3 Start focus on existing task

```text
Tasks
→ Select task/subtask
→ Start Session
→ Set duration (default 25)
→ Health gate if applicable
→ Start
→ Timer view
```

## 20.4 Start focus on ad-hoc task

```text
Start Session
→ New Ad-hoc Task
→ Title
→ Category(s)
→ Save
→ Status becomes In Progress
→ Set duration
→ Start
```

## 20.5 Pause

```text
Running session
→ Pause
→ Timer stops counting focused time
→ Resume
```

## 20.6 End session

```text
Running session
→ End Session
→ End / Cancel
→ End-of-session modal
→ Completed task? Yes/No
→ Focus 1–5
→ Energy 1–5
→ Notes
→ Save
→ Task list
```

## 20.7 Take break

```text
Session logged
→ Take Break
→ Default 5 min
→ Optionally change duration
→ Start break
→ Break ends
→ Return to task/session selection
```

## 20.8 Ask Lifebot what to do

```text
User gives:
- free-time window(s)
- current energy

Lifebot reads:
- backlog
- task metadata
- previous focus logs
- health context

Lifebot returns:
- one best next task/subtask
- recommended session duration
- short reason
```

---

# 21. UI Design Direction

Use the Microsoft Clock Focus Sessions screenshots provided by the user as the main visual reference for the timer.

Design characteristics:

- dark,
- minimal,
- large circular progress ring,
- large countdown,
- strong visual focus,
- clean rounded controls,
- unobtrusive metadata,
- compact mini mode,
- full mode + collapsible always-on-top mini mode.

The app should feel lightweight and calm rather than like a productivity dashboard.

---

# 22. Acceptance Criteria for Functional v1

A v1 is ready when the user can:

1. Point the app to the `Personal Productivity` Obsidian vault.
2. Create a task with required and optional metadata.
3. Create nested subtasks.
4. Edit task metadata.
5. Change task status.
6. Drag tasks into a preferred manual order within status groups.
7. Browse tasks grouped by collapsible project sections.
8. Start a session from an existing task/subtask.
9. Create an ad-hoc task directly from the session-start flow.
10. Configure a focus duration with default 25 minutes.
11. Pause and resume.
12. End a session early.
13. Have paused time excluded from focused duration.
14. Complete the required end-of-session modal.
15. Automatically mark tasks/subtasks Done when selected.
16. Automatically complete parents when all children are Done.
17. Persist the session into the vault.
18. Take an optional configurable break with default 5 minutes.
19. Collapse a running session to an always-on-top mini timer.
20. Restore the full timer.
21. Close/reopen the app without corrupting task/session state.
22. Allow Hermes to parse the task and session files reliably.
23. Ask Lifebot for the best single next session and receive a task, duration, and short reason.
24. Apply the after-5pm health warning logic when health data is available.
25. Require and store an override reason when the health warning is bypassed.

---

# 23. Implementation Guidance for Coding Agent

The coding agent may choose the technical stack, but the implementation should preserve the product boundaries above.

Important architectural constraints:

- local-first,
- Obsidian vault is canonical,
- human-readable Markdown/YAML,
- stable IDs,
- desktop-first,
- mini always-on-top timer,
- no unnecessary backend,
- no cloud dependency required for the task app,
- separate app logic from Lifebot reasoning,
- keep the app small enough to behave like a utility rather than a workspace.

Where the PRD leaves implementation details unspecified, prefer the simplest reliable solution.

Do not add product features merely because the chosen framework makes them easy.

---

# 24. Recommended Build Order

### Phase 1 — Vault schema
- task file format,
- nested subtask schema,
- daily session-log schema,
- IDs,
- safe read/write utilities.

### Phase 2 — Task app
- task list,
- project grouping,
- status groups,
- create/edit,
- nested subtasks,
- drag ordering.

### Phase 3 — Focus timer
- task selection,
- ad-hoc task creation,
- configurable timer,
- pause/resume,
- mini mode,
- end-session logging,
- break timer.

### Phase 4 — Hermes Lifebot
- vault reader,
- backlog parsing,
- focus-log analysis,
- current-energy input,
- free-time-window input,
- best-next-session recommendation,
- session-length recommendation.

### Phase 5 — Health context
- Apple Health / Apple Watch sync,
- steps/workout parsing,
- after-5pm health gate,
- override-reason logging,
- health-aware Lifebot recommendations.

### Phase 6 — Behavioral learning
- historical time-of-day patterns,
- category effectiveness,
- effort/session-length patterns,
- break continuation patterns,
- movement/workout correlations.

---

# 25. Definition of Success

The system is successful if, after accumulating enough history, the user can ask:

> What should I do next?

and receive a recommendation that is grounded in:

- what actually matters,
- what fits the remaining time,
- current energy,
- historical effectiveness,
- current productivity load,
- health context,

while the actual process of creating tasks and starting/logging sessions remains extremely low-friction.
