module digger_web;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.functional;
import std.path;
import std.process;
import std.string;

static if(!is(typeof({import ae.net.asockets;}))) static assert(false, "ae library not found, did you clone with --recursive?"); else:

import ae.net.asockets;
import ae.net.http.client;
import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.cmd;
import ae.sys.timing;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta : isDebug;

import common;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

// http://d.puremagic.com/issues/show_bug.cgi?id=12481
alias pipe = std.process.pipe;

// ***************************************************************************

class WebFrontend
{
	HttpServer httpd;
	ushort port;

	this(string host, ushort port)
	{
		httpd = new HttpServer();
		httpd.handleRequest = &onRequest;
		this.port = httpd.listen(port, host);

		addShutdownHandler(&httpd.close);
	}

	void onRequest(HttpRequest request, HttpServerConnection conn)
	{
		HttpResponseEx resp = new HttpResponseEx();
		resp.disableCache();

		string resource = request.resource;
		auto queryTuple = resource.findSplit("?");
		resource = queryTuple[0];
		auto params = decodeUrlParameters(queryTuple[2]);
		auto segments = resource.split("/")[1..$];

		switch (segments[0])
		{
			case "initialize":
			case "begin":
			case "merge":
			case "unmerge":
			case "merge-fork":
			case "unmerge-fork":
			case "build":
			case "install-preview":
			case "install":
			{
				auto paramsArray = params
					.pairs
					.filter!(pair => !pair.value.empty)
					.map!(pair => "--" ~ pair.key ~ "=" ~ pair.value)
					.array;
				startTask(segments ~ paramsArray);
				return conn.sendResponse(resp.serveJson("OK"));
			}
			case "pull-state.json":
				// Proxy request to GHDaemon, a daemon which caches GitHub
				// pull request test results. Required to avoid GitHub API
				// throttling without exposing a secret authentication token.
				// https://github.com/CyberShadow/GHDaemon
				enforce(resource.startsWith("/"), "Invalid resource");
				return httpRequest(
					new HttpRequest("http://ghdaemon.k3.1azy.net" ~ resource),
					(HttpResponse response, string disconnectReason)
					{
						if (conn.conn.connected)
							conn.sendResponse(response);
					}
				);
			case "refs.json":
			{
				struct Refs { string[] branches, tags; }
				auto refs = Refs(
					diggerQuery("branches"),
					diggerQuery("tags"),
				);
				return conn.sendResponse(resp.serveJson(refs));
			}
			case "status.json":
			{
				enforce(currentTask, "No task was started");

				struct Status
				{
					immutable(Task.OutputLine)[] lines;
					string state;
				}
				Status status;
				status.lines = currentTask.flushLines();
				status.state = text(currentTask.getState()).split(".")[$-1];
				return conn.sendResponse(resp.serveJson(status));
			}
			case "ping":
				lastPing = Clock.currTime;
				return conn.sendResponse(resp.serveJson("OK"));
			case "exit":
				log("Exit requested.");
				shutdown();
				return conn.sendResponse(resp.serveJson("OK"));
			default:
				return conn.sendResponse(resp.serveFile(resource[1..$], "web/"));
		}
	}
}

// ***************************************************************************

SysTime lastPing;

enum watchdogTimeout = 5.seconds;

void watchdog()
{
	if (exiting)
		return;
	if (lastPing != SysTime.init && Clock.currTime - lastPing > watchdogTimeout)
	{
		log("No ping request in %s, exiting".format(watchdogTimeout));
		return shutdown();
	}
	setTimeout(toDelegate(&watchdog), 100.msecs);
}

bool exiting;

void startWatchdog()
{
	addShutdownHandler({ exiting = true; });
	debug(ASOCKETS) {} else
		watchdog();
}

// ***************************************************************************

class Task
{
	enum State { none, running, error, complete }

	struct OutputLine
	{
		string text;
		bool error;
	}

	this(string[] args...)
	{
		import core.thread;

		void pipeLines(Pipe pipe, bool error)
		{
			// Copy the File to heap
			auto f = [pipe.readEnd].ptr;

			void run()
			{
				while (!f.eof)
				{
					auto s = f.readln();
					if (s.length == 0)
					{
						Thread.sleep(1.msecs);
						continue;
					}
					writeToConsole("%s: %s".format("OE"[error], s));
					synchronized(this)
						lines ~= OutputLine(s, error);
				}
				f.close();
			}

			auto t = new Thread(&run);
			t.isDaemon = true;
			t.start();
		}

		auto outPipe = pipe();
		auto errPipe = pipe();

		pipeLines(outPipe, false);
		pipeLines(errPipe, true );

		import std.stdio : stdin;
		pid = spawnProcess(
			[absolutePath("digger"), "do"] ~ args,
			stdin,
			outPipe.writeEnd,
			errPipe.writeEnd,
			null,
			isDebug ? Config.none : Config.suppressConsole,
		);
	}

	State getState()
	{
		auto result = pid.tryWait();
		if (result.terminated)
		{
			if (result.status == 0)
				return State.complete;
			else
				return State.error;
		}
		else
			return State.running;
	}

	immutable(OutputLine)[] flushLines()
	{
		synchronized(this)
		{
			auto result = lines;
			lines = null;
			return result;
		}
	}

private:
	Pid pid;
	immutable(OutputLine)[] lines;
}

Task currentTask;

bool taskRunning()
{
	return currentTask && currentTask.getState() == Task.State.running;
}

void startTask(string[] args...)
{
	enforce(!taskRunning(), "A task is already running");
	currentTask = new Task(args);
}

shared static this()
{
	addShutdownHandler({
		if (taskRunning())
		{
			log("Waiting for current task to finish...");
			currentTask.pid.wait();
			log("Task finished, exiting.");
		}
	 });
}

// ***************************************************************************

string[] diggerQuery(string[] args...)
{
	return query([absolutePath("digger"), "do"] ~ args)
		.splitLines()
		// filter out log lines
		.filter!(line => !line.startsWith("digger: "))
		.array();
}

// ***************************************************************************

/// Try to figure out if this is a desktop machine
/// which can run a graphical web browser, or a
/// headless machine which can't.
/// Either open the URL directly, or just print it
/// and invite the user to do so themselves.
void showURL(string host, ushort port)
{
	auto url = "http://%s:%s/".format(host, port);

	version (Windows)
		enum desktop = true;
	else
	version (OSX)
		enum desktop = true;
	else
		bool desktop = environment.get("DISPLAY") != "";

	if (desktop)
	{
		import std.process;
		log("Opening URL: " ~ url);
		browse(url);
	}
	else
	{
		// TODO: replace "localhost" with the server's hostname.
		log("To continue, please browse to: " ~ url);
	}
}

WebFrontend web;

void diggerWeb(
	Option!(string, "Interface to listen on.\nDefault is \"localhost\" (local connections only).", "HOST") host = "localhost",
	Option!(ushort, "Port to listen on. Default is 0 (random unused port).") port = 0)
{
	web = new WebFrontend(host, port);

	showURL(host, web.port);

	startWatchdog();

	socketManager.loop();
}

mixin main!(funopt!diggerWeb);
