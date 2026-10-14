#!/usr/bin/env node
// QA stand version switch: runs ./set-version.sh --silent on the host, see README "QA Tools".
// Auth is the QA tools basic auth (user qa, QA_TOOLS_PASSWORD), checked here too.

import { execFile, spawn } from 'node:child_process'
import { timingSafeEqual } from 'node:crypto'
import { createWriteStream, lchownSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { createServer } from 'node:http'
import { join } from 'node:path'

const ROOT = process.cwd()
const CONFIG_FILE = join(ROOT, 'config/platform.conf')
const LOG_FILE = join(ROOT, 'config/qa/set-version.log')
const PORT = Number(process.env.STAND_CONTROL_PORT ?? 4090)
// The version ends up in image tags and a command line: allow only a plain tag.
const VERSION_RE = /^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$/

let running = false

function readConf () {
  const conf = {}
  for (const line of readFileSync(CONFIG_FILE, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line)
    if (m !== null) conf[m[1]] = m[2].replace(/^"(.*)"$/, '$1')
  }
  return conf
}

function authorized (req) {
  const password = readConf().QA_TOOLS_PASSWORD ?? ''
  if (password === '') return false
  const expected = Buffer.from('Basic ' + Buffer.from('qa:' + password).toString('base64'))
  const got = Buffer.from(req.headers.authorization ?? '')
  return got.length === expected.length && timingSafeEqual(got, expected)
}

function readText (file) {
  try {
    return readFileSync(file, 'utf8')
  } catch {
    return ''
  }
}

function status () {
  return {
    version: readText(join(ROOT, 'config/version.txt')).trim(),
    running,
    log: readText(LOG_FILE).split('\n').slice(-200).join('\n')
  }
}

// Under root, set-version.sh leaves root-owned files; give config/ back to the repo owner.
function restoreOwner () {
  if (process.getuid?.() !== 0) return
  const { uid, gid } = statSync(ROOT)
  const configDir = join(ROOT, 'config')
  lchownSync(configDir, uid, gid)
  for (const name of readdirSync(configDir, { recursive: true })) {
    lchownSync(join(configDir, name), uid, gid)
  }
}

function apply (version) {
  running = true
  const log = createWriteStream(LOG_FILE)
  const finish = (message) => {
    if (!running) return
    log.end(message)
    try {
      restoreOwner()
    } catch (err) {
      console.error('Failed to restore config/ owner:', err)
    }
    running = false
  }

  const image = `${readConf().IMAGE_PREFIX || 'intabiafusion'}/transactor:${version}`
  // set-version.sh rewrites the config before pulling; a missing tag would leave it pointing nowhere.
  execFile('docker', ['manifest', 'inspect', image], (err) => {
    if (err !== null) {
      finish(`Image ${image} not found, nothing changed.\n`)
      return
    }
    const child = spawn('bash', ['./set-version.sh', '--silent', version], { cwd: ROOT })
    child.stdout.pipe(log, { end: false })
    child.stderr.pipe(log, { end: false })
    child.on('error', (err) => finish(`Failed to start set-version.sh: ${err.message}\n`))
    child.on('close', (code) => finish(`\nset-version.sh exited with code ${code}\n`))
  })
}

function readBody (req) {
  return new Promise((resolve, reject) => {
    let body = ''
    req.on('data', (chunk) => {
      body += chunk
      if (body.length > 1024) reject(new Error('Body too large'))
    })
    req.on('end', () => resolve(body))
    req.on('error', reject)
  })
}

function sendJson (res, code, data) {
  res.writeHead(code, { 'Content-Type': 'application/json' }).end(JSON.stringify(data))
}

const PAGE = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Stand Version</title>
<style>
body { font-family: -apple-system, sans-serif; max-width: 760px; margin: 2rem auto; padding: 0 1rem; color: #222; }
h1 { font-size: 1.4rem; } input, button { font-size: 1rem; padding: .3rem; }
pre { background: #f4f4f4; padding: .75rem; overflow-x: auto; max-height: 30rem; }
</style>
</head>
<body>
<h1>Stand Version</h1>
<p><a href="/_stand/">Stand info</a></p>
<p>Current version: <b id="current"></b> <span id="state"></span></p>
<form id="apply">
<input name="version" placeholder="v0.8.57" required>
<button id="submit">Apply</button>
</form>
<p>Same as <code>./set-version.sh --silent &lt;version&gt;</code>: pulls the images and restarts the changed services.</p>
<h2>Last run</h2>
<pre id="log"></pre>
<script>
const form = document.getElementById('apply')
let timer
async function refresh () {
  const s = await (await fetch('api/version')).json()
  document.getElementById('current').textContent = s.version
  document.getElementById('state').textContent = s.running ? '- update in progress' : ''
  document.getElementById('log').textContent = s.log
  document.getElementById('submit').disabled = s.running
  if (form.version.value === '') form.version.value = s.version
  clearTimeout(timer)
  if (s.running) timer = setTimeout(refresh, 3000)
}
form.onsubmit = async (e) => {
  e.preventDefault()
  const version = form.version.value.trim()
  if (!confirm('Apply ' + version + '? Services will be restarted.')) return
  const res = await fetch('api/version', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ version })
  })
  const data = await res.json()
  if (!res.ok) alert(data.error)
  refresh()
}
refresh()
</script>
</body>
</html>
`

const server = createServer(async (req, res) => {
  if (!authorized(req)) {
    res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="QA tools"' }).end()
    return
  }
  const { pathname } = new URL(req.url ?? '/', 'http://localhost')

  if (req.method === 'GET' && pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }).end(PAGE)
    return
  }
  if (req.method === 'GET' && pathname === '/api/version') {
    sendJson(res, 200, status())
    return
  }
  if (req.method === 'POST' && pathname === '/api/version') {
    // A cross-site form cannot send JSON without a CORS preflight, and preflights are never answered.
    if (req.headers['content-type'] !== 'application/json') {
      sendJson(res, 415, { error: 'Expected application/json' })
      return
    }
    let version
    try {
      version = JSON.parse(await readBody(req)).version
    } catch {
      sendJson(res, 400, { error: 'Invalid request body' })
      return
    }
    if (typeof version !== 'string' || !VERSION_RE.test(version)) {
      sendJson(res, 400, { error: 'Invalid version, expected vX.Y.Z' })
      return
    }
    if (running) {
      sendJson(res, 409, { error: 'Another update is running' })
      return
    }
    apply(version)
    sendJson(res, 202, { started: version })
    return
  }
  sendJson(res, 404, { error: 'Not found' })
})

server.listen(PORT, () => {
  console.log(`stand-control listening on :${PORT}, repo ${ROOT}`)
})
