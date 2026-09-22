#!/usr/bin/env node
import {run} from "./cli.js"

const {exitCode, output} = run(process.argv.slice(2))
process.stdout.write(output)
process.exitCode = exitCode
