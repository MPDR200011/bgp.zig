## TODOs

- [x] Adj Rib Subscriber model
- [x] Main Rib Subscriber model
- [x] Universal/Shared Async task executor for RIB operations
- [x] Address in-flight threadpool tasks at deinit time
- [ ] IMPORTANT: Main rib can't send updates back to advertisers


## Ideas

- ThreadPool with channels, you can only have one task per channel executing at any given time
  - Each channel has its own queue, threads look for tasks in any queue
