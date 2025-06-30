## TODOs

- AdjRib lifecycle
  - Init when session transitions to ESTABLISHED
  - Close down/clean up when session ends:
    - Fatals
    - Everything else

- [ ] Adj Rib Subscriber model
- [ ] Main Rib Subscriber model
- [ ] Universal/Shared Async task executor for RIB operations


## Ideas

- ThreadPool with channels, you can only have one task per channel executing at any given time
  - Each channel has its own queue, threads look for tasks in any queue
