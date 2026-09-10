#include <gtest/gtest.h>
#include "logos_core.h"
#include "dummy_module_generator.h"
#include <QTemporaryDir>
#include <string>
#include <thread>
#include <vector>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <cstring>

// Reusable barrier so all threads start work at the same instant.
class Barrier {
public:
    explicit Barrier(int count) : m_threshold(count), m_waiting(0), m_generation(0) {}

    void wait() {
        std::unique_lock<std::mutex> lock(m_mutex);
        int gen = m_generation;
        if (++m_waiting == m_threshold) {
            m_generation++;
            m_waiting = 0;
            m_cv.notify_all();
        } else {
            m_cv.wait(lock, [&] { return gen != m_generation; });
        }
    }

private:
    std::mutex m_mutex;
    std::condition_variable m_cv;
    int m_threshold;
    int m_waiting;
    int m_generation;
};

// Free a null-terminated array of strings allocated with new[].
static void freeStringArray(char** arr) {
    if (!arr) return;
    for (int i = 0; arr[i]; ++i)
        delete[] arr[i];
    delete[] arr;
}

// Count entries in a null-terminated string array.
static int stringArrayLen(char** arr) {
    if (!arr) return 0;
    int n = 0;
    while (arr[n]) ++n;
    return n;
}

// Return true if name appears in a null-terminated string array.
static bool stringArrayContains(char** arr, const char* name) {
    if (!arr) return false;
    for (int i = 0; arr[i]; ++i)
        if (strcmp(arr[i], name) == 0) return true;
    return false;
}

// Qt requires at least one argument (the program name) for QCoreApplication.
static int    s_argc    = 1;
static char   s_name[]  = "thread_safety_tests";
static char*  s_argv[]  = {s_name, nullptr};

static void initPluginState() {
    logos_core_init(s_argc, s_argv);
    logos_core_start();
}

static void initPluginState(const char* pluginsDir) {
    logos_core_init(s_argc, s_argv);
    logos_core_add_modules_dir(pluginsDir);
    logos_core_start();
}

// =============================================================================
// Lightweight tests — no real plugin files needed. Exercise the C API with
// names that are unknown to the registry.
// =============================================================================

class PluginApiTest : public ::testing::Test {
protected:
    void SetUp() override { initPluginState(); }
    void TearDown() override { logos_core_cleanup(); }

    static constexpr int kThreads = 8;
    static constexpr int kIterations = 200;
};

// -----------------------------------------------------------------------------
// Multiple threads all try to load unknown plugins concurrently.
// Every call must return 0 (failure) without crashing.
// -----------------------------------------------------------------------------
TEST_F(PluginApiTest, ConcurrentLoadUnknownPlugins) {
    Barrier barrier(kThreads);
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&barrier, t]() {
            barrier.wait();
            for (int i = 0; i < kIterations; ++i) {
                std::string name = "unknown_" + std::to_string(t) + "_" + std::to_string(i);
                int ok = logos_core_load_module(name.c_str(), LOGOS_LOAD_MODULE_ONLY);
                EXPECT_EQ(ok, 0);
            }
        });
    }

    for (auto& th : threads) th.join();
}

// -----------------------------------------------------------------------------
// logos_core_load_module(…, LOGOS_LOAD_REQUIRED_DEPS) on unknown plugins from
// many threads.
// Each call must return 0 (failure) without crashing.
// -----------------------------------------------------------------------------
TEST_F(PluginApiTest, ConcurrentLoadWithDepsUnknown) {
    Barrier barrier(kThreads);
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&barrier, t]() {
            barrier.wait();
            for (int i = 0; i < kIterations; ++i) {
                std::string name = "nodeps_" + std::to_string(t) + "_" + std::to_string(i);
                int rc = logos_core_load_module(name.c_str(), LOGOS_LOAD_REQUIRED_DEPS);
                EXPECT_EQ(rc, 0);
            }
        });
    }

    for (auto& th : threads) th.join();
}

// =============================================================================
// Real-plugin tests — use binary-patched copies of a real Qt plugin.
// All operations go through the public logos_core C API.
// =============================================================================

static constexpr int kModuleCount = 100;

// GENERATED ONCE, BEFORE THE FIRST CORE EXISTS, and shared by every test.
//
// Not merely to save the work. Generating a module SPAWNS a process (codesign,
// on Apple), and a live core has an async child reaper that will take the exit
// status of any child, including one it never started — so the QProcess wait
// inside the generator hangs on a process that has already exited. Doing all
// the generation from a gtest global environment puts it strictly before
// logos_core_init(), where there is no reaper to race.
class DummyModules : public ::testing::Environment {
public:
    static DummyModules& instance() { return *s_instance; }

    void SetUp() override {
        if (!m_dir.isValid()) return;
        m_modules = DummyModuleGenerator::generate(kModuleCount, m_dir.path());
    }

    const QVector<DummyModule>& modules() const { return m_modules; }
    QString path() const { return m_dir.path(); }

private:
    QTemporaryDir m_dir;
    QVector<DummyModule> m_modules;

    static DummyModules* s_instance;
};

DummyModules* DummyModules::s_instance = [] {
    auto* env = new DummyModules;
    ::testing::AddGlobalTestEnvironment(env);
    return env;
}();

class RealPluginThreadSafetyTest : public ::testing::Test {
protected:
    static constexpr int kThreads = 8;
    static constexpr int kIterations = 200;

    const QVector<DummyModule>& modules = DummyModules::instance().modules();

    void SetUp() override {
        if (modules.isEmpty())
            GTEST_SKIP() << "Dummy plugin template not found — skipping real-plugin tests";
        ASSERT_EQ(modules.size(), kModuleCount) << "Partial plugin generation — expected "
            << kModuleCount << " but got " << modules.size();
        std::string dir = DummyModules::instance().path().toStdString();
        initPluginState(dir.c_str());
    }

    void TearDown() override {
        logos_core_cleanup();
    }
};

// -----------------------------------------------------------------------------
// Each thread processes a disjoint slice of the generated plugins via
// logos_core_process_module. After joining, every plugin must appear in
// logos_core_get_known_modules().
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentProcessPlugins) {
    Barrier barrier(kThreads);
    std::atomic<int> processed{0};
    std::vector<std::thread> threads;

    int perThread = kModuleCount / kThreads;

    for (int t = 0; t < kThreads; ++t) {
        int start = t * perThread;
        int end = (t == kThreads - 1) ? kModuleCount : start + perThread;

        threads.emplace_back([&, start, end]() {
            barrier.wait();
            for (int i = start; i < end; ++i) {
                std::string path = modules[i].path.toStdString();
                char* name = logos_core_process_module(path.c_str());
                if (name) {
                    processed.fetch_add(1, std::memory_order_relaxed);
                    delete[] name;
                }
            }
        });
    }

    for (auto& th : threads) th.join();

    EXPECT_EQ(processed.load(), kModuleCount);

    char** known = logos_core_get_known_modules();
    EXPECT_EQ(stringArrayLen(known), kModuleCount);
    for (const DummyModule& m : modules) {
        std::string name = m.name.toStdString();
        EXPECT_TRUE(stringArrayContains(known, name.c_str())) << name;
    }
    freeStringArray(known);
}

// -----------------------------------------------------------------------------
// All threads try to process the SAME set of plugins — tests idempotent
// insertion under heavy write contention.
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentProcessSamePlugins) {
    Barrier barrier(kThreads);
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&]() {
            barrier.wait();
            for (const DummyModule& m : modules) {
                std::string path = m.path.toStdString();
                char* name = logos_core_process_module(path.c_str());
                delete[] name;
            }
        });
    }

    for (auto& th : threads) th.join();

    char** known = logos_core_get_known_modules();
    EXPECT_EQ(stringArrayLen(known), kModuleCount);
    freeStringArray(known);
}

// -----------------------------------------------------------------------------
// Half the threads process plugins while the other half continuously call
// logos_core_get_known_modules(). Tests reader safety during concurrent writes.
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentProcessWhileQuerying) {
    Barrier barrier(kThreads);
    std::atomic<int> writersDone{0};
    std::vector<std::thread> threads;

    int writers = kThreads / 2;

    for (int t = 0; t < writers; ++t) {
        int start = t * (kModuleCount / writers);
        int end = (t == writers - 1) ? kModuleCount : start + (kModuleCount / writers);

        threads.emplace_back([&, start, end]() {
            barrier.wait();
            for (int i = start; i < end; ++i) {
                std::string path = modules[i].path.toStdString();
                char* name = logos_core_process_module(path.c_str());
                delete[] name;
            }
            writersDone.fetch_add(1, std::memory_order_release);
        });
    }

    for (int t = writers; t < kThreads; ++t) {
        threads.emplace_back([&, writers]() {
            barrier.wait();
            while (writersDone.load(std::memory_order_acquire) < writers) {
                char** known = logos_core_get_known_modules();
                int len = stringArrayLen(known);
                EXPECT_GE(len, 0);
                freeStringArray(known);
            }
        });
    }

    for (auto& th : threads) th.join();

    char** known = logos_core_get_known_modules();
    EXPECT_EQ(stringArrayLen(known), kModuleCount);
    freeStringArray(known);
}

// -----------------------------------------------------------------------------
// logos_core_get_known_modules() and logos_core_get_loaded_modules() are called
// concurrently while other threads repeatedly load and unload a small set of
// plugins. Tests that the list accessors are safe under concurrent state
// changes.
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentGetListsDuringLoadUnload) {
    constexpr int kSmall = kThreads;
    for (int i = 0; i < kSmall; ++i) {
        std::string path = modules[i].path.toStdString();
        char* name = logos_core_process_module(path.c_str());
        delete[] name;
    }

    Barrier barrier(kThreads);
    std::atomic<bool> done{false};
    std::vector<std::thread> threads;

    // Writer threads repeatedly load then unload the same small set.
    threads.emplace_back([&]() {
        barrier.wait();
        for (int iter = 0; iter < kIterations; ++iter) {
            std::string name = modules[iter % kSmall].name.toStdString();
            (void)logos_core_load_module(name.c_str(), LOGOS_LOAD_MODULE_ONLY);
            (void)logos_core_unload_module(name.c_str(), false);
        }
        done.store(true, std::memory_order_release);
    });

    // Reader threads call both list accessors in a tight loop.
    for (int t = 1; t < kThreads; ++t) {
        threads.emplace_back([&]() {
            barrier.wait();
            while (!done.load(std::memory_order_acquire)) {
                char** known = logos_core_get_known_modules();
                EXPECT_NE(known, nullptr);
                freeStringArray(known);

                char** loaded = logos_core_get_loaded_modules();
                EXPECT_NE(loaded, nullptr);
                freeStringArray(loaded);
            }
        });
    }

    for (auto& th : threads) th.join();
}

// -----------------------------------------------------------------------------
// Process all plugins, then each thread loads a disjoint slice via
// logos_core_load_module. Tests the load path under concurrent pressure.
// With logos_host available (LOGOS_HOST_PATH set), loads succeed; without it
// they return 0. Either way the registry must remain consistent.
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentLoadPlugin) {
    for (const DummyModule& m : modules) {
        std::string path = m.path.toStdString();
        char* name = logos_core_process_module(path.c_str());
        delete[] name;
    }

    {
        char** known = logos_core_get_known_modules();
        ASSERT_EQ(stringArrayLen(known), kModuleCount);
        freeStringArray(known);
    }

    Barrier barrier(kThreads);
    std::vector<std::thread> threads;

    int perThread = kModuleCount / kThreads;

    for (int t = 0; t < kThreads; ++t) {
        int start = t * perThread;
        int end = (t == kThreads - 1) ? kModuleCount : start + perThread;

        threads.emplace_back([&, start, end]() {
            barrier.wait();
            for (int i = start; i < end; ++i) {
                std::string name = modules[i].name.toStdString();
                (void)logos_core_load_module(name.c_str(), LOGOS_LOAD_MODULE_ONLY);
            }
        });
    }

    for (auto& th : threads) th.join();

    char** known = logos_core_get_known_modules();
    EXPECT_EQ(stringArrayLen(known), kModuleCount);
    for (const DummyModule& m : modules) {
        std::string name = m.name.toStdString();
        EXPECT_TRUE(stringArrayContains(known, name.c_str())) << name;
    }
    freeStringArray(known);
}

// -----------------------------------------------------------------------------
// All threads hammer the SAME small set of plugins with logos_core_load_module.
// Tests mutex contention and the "already loaded" fast-return branch.
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentLoadSamePlugin) {
    constexpr int kSmall = kThreads;
    for (int i = 0; i < kSmall; ++i) {
        std::string path = modules[i].path.toStdString();
        char* name = logos_core_process_module(path.c_str());
        delete[] name;
    }

    {
        char** known = logos_core_get_known_modules();
        ASSERT_EQ(stringArrayLen(known), kSmall);
        freeStringArray(known);
    }

    Barrier barrier(kThreads);
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&]() {
            barrier.wait();
            for (int i = 0; i < kSmall; ++i) {
                std::string name = modules[i].name.toStdString();
                (void)logos_core_load_module(name.c_str(), LOGOS_LOAD_MODULE_ONLY);
            }
        });
    }

    for (auto& th : threads) th.join();

    char** known = logos_core_get_known_modules();
    EXPECT_EQ(stringArrayLen(known), kSmall);
    freeStringArray(known);
}

// -----------------------------------------------------------------------------
// Each thread loads a disjoint slice via
// logos_core_load_module(…, LOGOS_LOAD_REQUIRED_DEPS).
// Tests dependency resolution and loadMutex acquisition from multiple threads.
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentLoadWithDeps) {
    for (const DummyModule& m : modules) {
        std::string path = m.path.toStdString();
        char* name = logos_core_process_module(path.c_str());
        delete[] name;
    }

    {
        char** known = logos_core_get_known_modules();
        ASSERT_EQ(stringArrayLen(known), kModuleCount);
        freeStringArray(known);
    }

    Barrier barrier(kThreads);
    std::vector<std::thread> threads;

    int perThread = kModuleCount / kThreads;

    for (int t = 0; t < kThreads; ++t) {
        int start = t * perThread;
        int end = (t == kThreads - 1) ? kModuleCount : start + perThread;

        threads.emplace_back([&, start, end]() {
            barrier.wait();
            for (int i = start; i < end; ++i) {
                std::string name = modules[i].name.toStdString();
                (void)logos_core_load_module(name.c_str(), LOGOS_LOAD_REQUIRED_DEPS);
            }
        });
    }

    for (auto& th : threads) th.join();

    char** known = logos_core_get_known_modules();
    EXPECT_EQ(stringArrayLen(known), kModuleCount);
    freeStringArray(known);
}

// -----------------------------------------------------------------------------
// Half the threads call logos_core_load_module while the other half call
// logos_core_unload_module on the same small module set. Tests the load/unload
// interplay under concurrent pressure.
// -----------------------------------------------------------------------------
TEST_F(RealPluginThreadSafetyTest, ConcurrentLoadUnloadInterleaved) {
    constexpr int kSmall = kThreads;
    for (int i = 0; i < kSmall; ++i) {
        std::string path = modules[i].path.toStdString();
        char* name = logos_core_process_module(path.c_str());
        delete[] name;
    }

    {
        char** known = logos_core_get_known_modules();
        ASSERT_EQ(stringArrayLen(known), kSmall);
        freeStringArray(known);
    }

    Barrier barrier(kThreads);
    std::vector<std::thread> threads;

    int loaders   = kThreads / 2;
    int unloaders = kThreads - loaders;

    for (int t = 0; t < loaders; ++t) {
        threads.emplace_back([&]() {
            barrier.wait();
            for (int iter = 0; iter < 10; ++iter) {
                for (int i = 0; i < kSmall; ++i) {
                    std::string name = modules[i].name.toStdString();
                    (void)logos_core_load_module(name.c_str(), LOGOS_LOAD_MODULE_ONLY);
                }
            }
        });
    }

    for (int t = 0; t < unloaders; ++t) {
        threads.emplace_back([&]() {
            barrier.wait();
            for (int iter = 0; iter < 10; ++iter) {
                for (int i = 0; i < kSmall; ++i) {
                    std::string name = modules[i].name.toStdString();
                    (void)logos_core_unload_module(name.c_str(), false);
                }
            }
        });
    }

    for (auto& th : threads) th.join();

    // All modules must still be registered; load/unload must not corrupt the registry.
    char** known = logos_core_get_known_modules();
    EXPECT_EQ(stringArrayLen(known), kSmall);
    for (int i = 0; i < kSmall; ++i) {
        std::string name = modules[i].name.toStdString();
        EXPECT_TRUE(stringArrayContains(known, name.c_str())) << name;
    }
    freeStringArray(known);
}
