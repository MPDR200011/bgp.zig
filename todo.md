## TODOs

- Add context to RoutePath:
  - Assigned when route is introduced into main rib
  - Adj rib managers hold the context, which is assigned at creation when the
  session switches to ESTABLISHED
  - Should hold:
    - Session addresses
    - Session ASNs
    - Session peer ids
  - IMPORTANT: complete the RoutePath.neighboringAS() and cmp() methods by
  using that information.
- Verify support for empty AS Path from and to internal peers
- Periodic task that restarts peer sessions
- MinRouteAdvertisementIntervalTimer
- When a BGP speaker receives an UPDATE message from an internal peer, the
receiving BGP speaker SHALL NOT re-distribute the routing information contained
in that UPDATE message to other internal peers (unless the speaker acts as a
BGP Route Reflector [RFC2796]).

- Phase 2: Route Selection:
    - Finish tie break logic
    - "The Phase 2 decision function is blocked from running while the Phase 3
    decision function is in process.  The Phase 2 function locks all Adj-RIBs-In
    prior to commencing its function, and unlocks them on completion."

- Tag path as from internal vs external peers:
    - When a BGP speaker receives an UPDATE message from an internal peer, the
    receiving BGP speaker SHALL NOT re-distribute the routing information contained
    in that UPDATE message to other internal peers (unless the speaker acts as a
    BGP Route Reflector [RFC2796]).

- TODO: Message packaging, one message per prefix is naive
- FIXME: Connection Collision handling
- TODO: Peer Oscillation dampening
- TODO: If the DelayOpenTimer is running and the SendNOTIFICATIONwithoutOPEN
session attribute is set, the local system sends a NOTIFICATION with a Cease
- FIXME: implement message size limits
- TODO: handle the automatic stop event
- Origination policies
- Routing policy:
    - operation ideas:
        - set lpref
        - remove med
        - as path prepend
- Tie break routes by calculating the nexthop metric:
    - Requires other routing protocols to determine that...

## Ideas

- ThreadPool with channels, you can only have one task per channel executing at any given time
  - Each channel has its own queue, threads look for tasks in any queue
