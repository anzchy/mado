#!/usr/bin/env node
import { verifyAtomicCompiler } from './coverage-atomic.mjs';
try { console.log(`coverage-atomic: ${JSON.stringify(verifyAtomicCompiler())}`); }
catch (error) { console.error(`coverage-atomic: ${error.message}`); process.exitCode = 1; }
