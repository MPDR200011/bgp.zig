## TODOs

- Route origination
- Transmit unrecognized optional transitive attributes
- Rename Path -> Route
- MinRouteAdvertisementIntervalTimer
- Phase 2: Route Selection
- "The Phase 2 decision function is blocked from running while the Phase 3
decision function is in process.  The Phase 2 function locks all Adj-RIBs-In
prior to commencing its function, and unlocks them on completion."
- Handling transitive, unknown transitive, etc.
- For well-known attributes, the Transitive bit MUST be set to 1.
- When a BGP speaker receives an UPDATE message from an internal peer, the
receiving BGP speaker SHALL NOT re-distribute the routing information contained
in that UPDATE message to other internal peers (unless the speaker acts as a
BGP Route Reflector [RFC2796]).
- A BGP speaker MUST implement a mechanism (based on local configuration) that
allows the MULTI_EXIT_DISC attribute to be removed from a route.  If a BGP
speaker is configured to remove the MULTI_EXIT_DISC attribute from a route,
then this removal MUST be done prior to determining the degree of preference of
the route and prior to performing route selection (Decision Process phases 1
and 2).

## Ideas

- ThreadPool with channels, you can only have one task per channel executing at any given time
  - Each channel has its own queue, threads look for tasks in any queue
