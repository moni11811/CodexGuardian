# Phase 7 event replay review

Owner: durable reconnect regression lane.

RED: focused compile failed because no durable daemon-event append or replay
API existed.

GREEN: generation/sequence event rows are now committed atomically with the
daemon cursor. Reopen replay returns ordered events; stale generations or a
missing durable event require a full snapshot. Focused tests passed 2/2.
