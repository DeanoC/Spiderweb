# Agent Runtime Layer

This folder contains the remaining Spider Monkey runtime bridge used by Spiderweb.

It is responsible for:

- agent runtime state and ticking
- provider orchestration
- internal capability execution for the still-hosted runtime path

This is internal runtime machinery that still needs extraction or simplification.
Public capability surfaces should continue to move toward Acheron namespaces and node-backed services rather than expanding direct runtime tooling here.
