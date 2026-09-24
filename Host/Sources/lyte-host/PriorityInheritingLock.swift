// A mutex with priority inheritance. The session lock is taken by the
// SCHED_RR sender thread and by default-priority threads (capture's frame
// commit, the janitor); without inheritance a preempted default-priority
// holder blocks the realtime sender for as long as the scheduler keeps
// it off the CPU.

import Glibc

/// PTHREAD_PRIO_INHERIT: while a higher-priority thread waits, the holder
/// runs at the waiter's priority. Non-recursive, like NSLock; unlocked
/// only by the thread that locked it.
final class PriorityInheritingLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        mutex = .allocate(capacity: 1)
        var attributes = pthread_mutexattr_t()
        pthread_mutexattr_init(&attributes)
        pthread_mutexattr_setprotocol(&attributes, Int32(PTHREAD_PRIO_INHERIT))
        pthread_mutex_init(mutex, &attributes)
        pthread_mutexattr_destroy(&attributes)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    func lock() { pthread_mutex_lock(mutex) }

    func unlock() { pthread_mutex_unlock(mutex) }

    /// Takes the lock only if it is free; never waits.
    func `try`() -> Bool { pthread_mutex_trylock(mutex) == 0 }
}
