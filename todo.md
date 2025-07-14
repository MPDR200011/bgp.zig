## TODOs

- [x] Adj Rib Subscriber model
- [x] Main Rib Subscriber model
- [x] Universal/Shared Async task executor for RIB operations
- [ ] Address in-flight threadpool tasks at deinit time


## Ideas

- ThreadPool with channels, you can only have one task per channel executing at any given time
  - Each channel has its own queue, threads look for tasks in any queue
