// Copyright 2021 Chris E. Holloway
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include "xtr/source.hpp"
#include "xtr/detail/consumer.hpp"
#include "xtr/logger.hpp"

#include <condition_variable>
#include <mutex>

XTR_FUNC
xtr::source::source(const source& other)
{
    *this = other;
}

XTR_FUNC
xtr::source& xtr::source::operator=(const source& other)
{
    if (this == &other) [[unlikely]]
        return *this;

    close();

    level_ = other.level_.load(std::memory_order_relaxed);

    if (other.open_)
    {
        const_cast<source&>(other).post(
            [this](detail::consumer& c, const auto& name) { c.add_source(*this, name); });
        open_ = true;
    }

    return *this;
}

XTR_FUNC
xtr::source::source(logger& owner, std::string name)
{
    owner.register_source(*this, std::move(name));
}

XTR_FUNC
void xtr::source::close()
{
    if (open_)
    {
        sync(/*destroy=*/true);
        open_ = false;
        // clear() is called here in case the source is registered with the
        // logger again, e.g. via assignment. This is because when the
        // 'destruct' flag is received by the consumer it cannot perform any
        // further operations on the source (as the source may no longer
        // exist), including updating the read offset of the ring buffer, which
        // means that some residual data will be left in the buffer that needs
        // to be cleared.
        buf_.clear();
    }
}

XTR_FUNC
bool xtr::source::is_open() const noexcept
{
    return open_;
}

XTR_FUNC
void xtr::source::sync(bool destroy)
{
    std::condition_variable cv;
    std::mutex m;
    bool notified = false; // protected by m

    post(
        [&cv, &m, &notified, destroy](detail::consumer& c, auto&)
        {
            c.destroy = destroy;

            c.flush();
            c.sync();

            std::scoped_lock lock{m};
            notified = true;
            // Do not move this notify outside of the protection of m. The
            // standard guarantees that a mutex may be destructed while
            // another thread is still inside unlock (but does not hold the
            // lock). From the mutex requirements:
            //
            // ``Note: After a thread A has called unlock(), releasing a
            // mutex, it is possible for another thread B to lock the same
            // mutex, observe that it is no longer in use, unlock it, and
            // destroy it, before thread A appears to have returned from
            // its unlock call. Implementations are required to handle such
            // scenarios correctly, as long as thread A doesn't access the
            // mutex after the unlock call returns.''
            //
            // No such requirement exists for condition_variable and notify,
            // which may access memory (e.g. an internal mutex in pthreads) in
            // the signalling thread after the waiting thread has woken up---so
            // if the lock is not held, the condition_variable could already
            // have been destructed at this time (due to the stack being
            // unwound).
            cv.notify_one();
            // Do not access any captured variables after notifying because if
            // the source is destructing then the underlying storage may have
            // been freed already.
        });

    std::unique_lock lock{m};
    while (!notified)
        cv.wait(lock);
}

XTR_FUNC
void xtr::source::set_name(std::string name)
{
    post(
        [name = std::move(name)](auto&, auto& oldname) mutable
        {
            oldname = std::move(name);
        });
    sync();
}

XTR_FUNC
xtr::source::~source()
{
    close();
}
