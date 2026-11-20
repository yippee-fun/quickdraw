// Runs Playwright for a browser test worker (see Bridge), with its public API.
// Launches the browser as soon as it starts, keeps the next test's page open
// in advance, and answers one request per line of stdin with one line of
// stdout: {id, op, ...} with {id, result} or {id, error}.
//
// Objects that aren't JSON, such as pages and locators, are kept here as
// handles, {$handle, $type}, and freed when the tab they came from closes.
// Arguments can refer to them, to a chain of calls on one ({$chain}), or to a
// RegExp ({$regexp}).
import { createRequire } from "node:module"
import { mkdir, writeFile } from "node:fs/promises"
import { dirname } from "node:path"
import { createInterface } from "node:readline"

const [packagePath, settingsJSON] = process.argv.slice(2)
const settings = JSON.parse(settingsJSON)
const playwright = createRequire(import.meta.url)(packagePath)

const handles = new Map()
let nextHandle = 1

const store = (object, tab) => {
	const id = nextHandle++
	handles.set(id, { object, tab })
	return id
}

const lookup = (id) => {
	const entry = handles.get(id)
	if (!entry) throw new Error(`Quickdraw’s handle ${id} is gone, since its page closed.`)
	return entry
}

const regexp = ({ source, flags }) => new RegExp(source, flags)

const isPlain = (value) => value !== null && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype

// Arguments from Ruby, with handles, chains and regexps made real.
const revive = async (value) => {
	if (Array.isArray(value)) return Promise.all(value.map(revive))
	if (!isPlain(value)) return value
	if ("$handle" in value) return lookup(value.$handle).object
	if ("$chain" in value) return run(lookup(value.$chain.target).object, value.$chain.chain)
	if ("$regexp" in value) return regexp(value.$regexp)
	const entries = await Promise.all(Object.entries(value).map(async ([key, item]) => [key, await revive(item)]))
	return Object.fromEntries(entries)
}

// Results for Ruby: JSON as it is, and anything else as a handle.
const serialize = (value, tab) => {
	if (value === undefined || value === null) return null
	if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value
	if (Buffer.isBuffer(value)) return { $binary: value.toString("base64") }
	if (Array.isArray(value)) return value.map((item) => serialize(item, tab))
	if (isPlain(value)) return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, serialize(item, tab)]))
	return { $handle: store(value, tab), $type: value.constructor?.name ?? typeof value }
}

// Methods whose first argument is JavaScript for the page. Ruby can only send
// it as a string, which Playwright takes for an expression, so one that's a
// function is made one, as Playwright's other language clients do.
const EVALUATES = new Set(["evaluate", "evaluateHandle", "evaluateAll", "waitForFunction", "$eval", "$$eval"])
const FUNCTION = /^\s*(async\b\s*)?(function\b|\(.*=>|[\w$]+\s*=>)/s

// The function a string of JavaScript defines, or the string, if it isn't one.
// Defining a function has no effects, and anything else that looks like one
// is only evaluated to see.
const functionOf = (source) => {
	if (!FUNCTION.test(source)) return source
	try {
		const value = new Function(`return (${source})`)()
		return typeof value === "function" ? value : source
	} catch {
		return source
	}
}

// Calls each [name, args] in turn on what the last returned, or reads a
// property, such as page.keyboard, when it isn't a function.
const run = async (object, chain) => {
	for (const [name, args] of chain) {
		const member = object[name]
		if (member === undefined) throw new Error(`${object.constructor?.name ?? typeof object} has no ${name}.`)
		if (typeof member !== "function") {
			object = member
			continue
		}

		const revived = await revive(args)
		if (EVALUATES.has(name) && typeof revived[0] === "string") revived[0] = functionOf(revived[0])
		object = await member.apply(object, revived)
	}
	return object
}

// The tab a handle's object belongs to, so results join it.
const tabOf = (id) => lookup(id).tab

const tabs = new Map()

const launching = (async () => {
	const type = playwright[settings.browser]
	const browser = await type.launch({ headless: settings.headless, ...(await revive(settings.launch)) })
	return browser
})()

const openTab = async () => {
	const browser = await launching
	const context = await browser.newContext({ baseURL: settings.baseURL ?? undefined, ...(await revive(settings.context)) })
	context.setDefaultTimeout(settings.timeout)
	const page = await context.newPage()
	const tab = { context, page, console: [] }
	page.on("console", (message) => tab.console.push(`${message.type()}: ${message.text()}`))
	page.on("pageerror", (error) => tab.console.push(`uncaught: ${error.message}`))
	// Handled as Playwright does without a listener: dismissed, but a page
	// that's leaving is let go.
	page.on("dialog", (dialog) => {
		tab.console.push(`dialog: ${dialog.type()}: ${dialog.message()}`)
		const handled = dialog.type() === "beforeunload" ? dialog.accept() : dialog.dismiss()
		handled.catch(() => {})
	})
	return tab
}

// Opened before a test asks for it, since a page is most of a test's overhead.
const prepare = () => {
	const opening = openTab()
	opening.catch(() => {})
	return opening
}

// Two, opened at once: tests that take a few milliseconds of their own wait
// on Chromium's ~30ms renderers. A third, or two with four or more workers,
// made no difference.
const spares = [prepare(), prepare()]

// A locator from Ruby: a selector, or a chain of calls on a handle.
const locate = async (page, target) => typeof target === "string" ? page.locator(target) : run(lookup(target.target).object, target.chain)

const describe = (target) => typeof target === "string" ? target : target.description

const quote = (text) => typeof text === "object" ? `/${text.source}/${text.flags}` : JSON.stringify(text)

const excerpt = (text) => JSON.stringify(text.length > 300 ? `${text.slice(0, 300)}…` : text)

// A RegExp for text as Playwright's toContainText matches a string: partly,
// case-sensitively, with any whitespace between its words.
const pattern = (text) => {
	if (typeof text === "object") return regexp(text)
	return new RegExp(text.trim().split(/\s+/).map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\s+"))
}

// For a locator's hasText filter, which matches a string case-insensitively.
const filterText = (text) => typeof text === "object" ? regexp(text) : text

const normalize = (text) => text.replace(/\s+/g, " ").trim()

const timedOut = (error) => error?.name === "TimeoutError"

// Polls `check` until it's true or `timeout` passes, as Playwright's expect does.
const poll = async (timeout, check) => {
	const deadline = Date.now() + timeout
	const intervals = [0, 20, 50, 100, 100, 250]
	for (let attempt = 0; ; attempt++) {
		if (await check()) return true
		const wait = intervals[Math.min(attempt, intervals.length - 1)]
		if (Date.now() + wait > deadline) return false
		await new Promise((resolve) => setTimeout(resolve, wait))
	}
}

// Waiting assertions. Each resolves to null if it passes, or why it failed.
const assertions = {
	async text({ page, within, text, timeout }) {
		const element = (await locate(page, within)).first()
		try {
			await element.filter({ hasText: pattern(text) }).waitFor({ state: "attached", timeout })
			return null
		} catch (error) {
			if (!timedOut(error)) throw error
			return `Expected ${describe(within)} to contain ${quote(text)}, but ${await found(element)} after ${timeout / 1000}s.`
		}
	},

	async noText({ page, within, text, timeout }) {
		const element = (await locate(page, within)).first()
		try {
			await element.filter({ hasNotText: pattern(text) }).waitFor({ state: "attached", timeout })
			return null
		} catch (error) {
			if (!timedOut(error)) throw error
			return `Expected ${describe(within)} not to contain ${quote(text)}, but ${await found(element)} after ${timeout / 1000}s.`
		}
	},

	async selector({ page, selector, text, count, timeout }) {
		const elements = (await locate(page, selector)).filter({ visible: true, ...(text == null ? {} : { hasText: filterText(text) }) })
		const matching = `matching ${describe(selector)}${text == null ? "" : ` with text ${quote(text)}`}`

		if (count == null) {
			try {
				await elements.first().waitFor({ state: "attached", timeout })
				return null
			} catch (error) {
				if (!timedOut(error)) throw error
				return `Expected a visible element ${matching}, but there was none after ${timeout / 1000}s.`
			}
		}

		let last = 0
		if (await poll(timeout, async () => (last = await elements.count()) === count)) return null
		return `Expected ${count} visible ${count === 1 ? "element" : "elements"} ${matching}, but there ${last === 1 ? "was" : "were"} ${last} after ${timeout / 1000}s.`
	},

	async noSelector({ page, selector, text, timeout }) {
		const elements = (await locate(page, selector)).filter({ visible: true, ...(text == null ? {} : { hasText: filterText(text) }) })
		try {
			await elements.first().waitFor({ state: "detached", timeout })
			return null
		} catch (error) {
			if (!timedOut(error)) throw error
			const count = await elements.count()
			return `Expected no visible element matching ${describe(selector)}${text == null ? "" : ` with text ${quote(text)}`}, but there ${count === 1 ? "was" : "were"} ${count} after ${timeout / 1000}s.`
		}
	},
}

// What an element's text was, for a failure message.
const found = async (element) => {
	const text = await element.innerText({ timeout: 100 }).catch(() => null)
	return text === null ? "nothing matched it" : `its text was ${excerpt(normalize(text))}`
}

const operations = {
	// The next test's page, with its tab.
	async open() {
		// Replaced first, so a page that failed to open isn't left a gap.
		const opening = spares.shift()
		spares.push(prepare())
		const tab = await opening
		// The page is the first of its tab's handles.
		const id = nextHandle++
		handles.set(id, { object: tab.page, tab: id })
		tabs.set(id, tab)
		return { $handle: id, $type: "Page" }
	},

	async close({ page }) {
		const tab = tabs.get(page)
		tabs.delete(page)
		for (const [id, entry] of handles) if (entry.tab === page) handles.delete(id)
		await tab.context.close()
		return null
	},

	async call({ target, chain }) {
		return serialize(await run(lookup(target).object, chain), tabOf(target))
	},

	async assert({ kind, page, ...options }) {
		return assertions[kind]({ page: lookup(page).object, ...options })
	},

	// Saves the page's screenshot, HTML and console log at `base` with those
	// extensions, and returns lines naming what it saved, or why it couldn't.
	async save({ page, base, timeout }) {
		const tab = tabs.get(page)
		const saved = []
		try {
			await mkdir(dirname(base), { recursive: true })
			await tab.page.screenshot({ path: `${base}.png`, fullPage: true, timeout })
			saved.push(["Screenshot", `${base}.png`])
			await writeFile(`${base}.html`, await tab.page.content())
			saved.push(["HTML", `${base}.html`])
			if (tab.console.length > 0) {
				await writeFile(`${base}.log`, tab.console.join("\n"))
				saved.push(["Console", `${base}.log`])
			}
		} catch (error) {
			saved.push(["Error", error.message.split("\n")[0]])
		}
		return saved
	},

	// Waits for the browser, so a failure to launch is reported once.
	async ready() {
		await launching
		return playwright[settings.browser].name()
	},
}

const reply = (message) => process.stdout.write(`${JSON.stringify(message)}\n`)

createInterface({ input: process.stdin }).on("line", async (line) => {
	const { id, op, ...params } = JSON.parse(line)
	try {
		reply({ id, result: await operations[op](params) })
	} catch (error) {
		reply({ id, error: { name: error.name, message: error.message } })
	}
}).on("close", async () => {
	await (await launching.catch(() => null))?.close().catch(() => {})
	process.exit(0)
})
