## TODOs

- [ ] Rib thread:
    - [ ] Adj-out -> peers
    - [ ] IMPORTANT: Main rib can't send updates back to advertisers
- [ ] Route origination
- [ ] Transmit unrecognized optional transitive attributes
- [ ] Rename Path -> Route
- [ ] BIRD Docker container
- MinRouteAdvertisementIntervalTimer
- Phase 2: Route Selection
- "The Phase 2 decision function is blocked from running while the Phase 3
decision function is in process.  The Phase 2 function locks all Adj-RIBs-In
prior to commencing its function, and unlocks them on completion."
- Handling transitive, unknown transitive, etc.


## Ideas

- ThreadPool with channels, you can only have one task per channel executing at any given time
  - Each channel has its own queue, threads look for tasks in any queue
