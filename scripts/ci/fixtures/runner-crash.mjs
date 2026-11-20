// #759: a test file that interrupts only its own test-runner parent, then exits 0. SIGKILL, because a runner may
// handle SIGTERM (Node's test runner does) and finish its in-flight file into a completed root.
export const runnerCrashFixture = 'process.kill(process.ppid,"SIGKILL");process.exit(0);\n';
