## TODOs

- [ ] Rib thread:
    - [ ] Adj-out -> peers
    - [ ] IMPORTANT: Main rib can't send updates back to advertisers
- [ ] Route origination
- [ ] Transmit unrecognized optional transitive attributes
- [ ] Rename Path -> Route
- [ ] BIRD Docker container


## Ideas

- ThreadPool with channels, you can only have one task per channel executing at any given time
  - Each channel has its own queue, threads look for tasks in any queue
