import assert from "node:assert/strict";
import test from "node:test";
import worker from "./index.js";

const ids = {
  inbox: "11111111-1111-1111-1111-111111111111",
  meetings: "22222222-2222-2222-2222-222222222222",
  tasks: "33333333-3333-3333-3333-333333333333",
  ideas: "44444444-4444-4444-4444-444444444444",
  recent: "55555555-5555-5555-5555-555555555555",
  processing: "66666666-6666-6666-6666-666666666666",
};

function environment() {
  return {
    NOTION_TOKEN: "test-notion-token",
    UPLOAD_TOKEN: "x".repeat(32),
    INBOX_PAGE_ID: ids.inbox,
    MEETINGS_DATABASE_ID: ids.meetings,
    TASKS_DATABASE_ID: ids.tasks,
    IDEAS_DATABASE_ID: ids.ideas,
    RECENT_DATABASE_ID: ids.recent,
    PROCESSING_DATABASE_ID: ids.processing,
    TIMEZONE_OFFSET: "-07:00",
    AI: {
      async run() {
        return { response: {
          area: "Work", area_confidence: 0.94, summary: "Planning discussion", project: "", client: "", people: [],
          meeting: { title: "Launch planning", participants: ["Hayden", "Carter"], decisions: ["Ship Friday"], open_questions: [], follow_up: "Review launch checklist" },
          tasks: [
            { title: "Prepare dashboard", owner: "Hayden", due_date: "2026-09-01", priority: "High", summary: "Prepare usage dashboard", source_quote: "I will prepare the dashboard" },
            { title: "Review risks", owner: "Carter", due_date: "", priority: "Medium", summary: "Review launch risks", source_quote: "I will review the risks" },
          ],
          ideas: [{ title: "Staged rollout", topic: "Launch", summary: "Roll out in stages", why_it_matters: "Reduces risk", next_experiment: "Pilot with one team" }],
        } };
      },
    },
  };
}

test("one transcript creates a meeting, multiple tasks, and an idea", async () => {
  const originalFetch = globalThis.fetch;
  const created = [];
  let nextPage = 10;
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const body = init.body ? JSON.parse(init.body) : null;
    if (url.pathname.endsWith(`/blocks/${ids.inbox}/children`)) return response({ results: [] });
    if (url.pathname.endsWith("/pages") && init.method === "POST") {
      const page = { id: `aaaaaaaa-aaaa-aaaa-aaaa-${String(nextPage++).padStart(12, "0")}`, url: `https://www.notion.so/test-${nextPage}` };
      created.push({ body, page });
      return response(page);
    }
    if (url.pathname.includes("/pages/") && !init.method) {
      return response({ id: "source", parent: { page_id: ids.inbox }, properties: { Name: { type: "title", title: [{ plain_text: "2026-08-31 10:00:00 · AnkerCore 1788200000" }] } }, created_time: "2026-08-31T17:00:00Z", url: "https://www.notion.so/source" });
    }
    if (url.pathname.includes("/blocks/") && url.pathname.endsWith("/children")) {
      return response({ results: [{ type: "paragraph", paragraph: { rich_text: [{ plain_text: "Hayden: I will prepare the dashboard. Carter: I will review the risks." }] } }] });
    }
    if (url.pathname.includes("/databases/") && url.pathname.endsWith("/query")) return response({ results: [] });
    if (url.pathname.includes("/pages/") && init.method === "PATCH") return response({ id: "updated" });
    throw new Error(`Unexpected Notion request: ${init.method || "GET"} ${url.pathname}`);
  };

  try {
    const request = new Request("https://example.test/transcript", {
      method: "POST",
      headers: { authorization: `Bearer ${"x".repeat(32)}`, "content-type": "application/json" },
      body: JSON.stringify({ file_id: "1788200000", recorded_at: "2026-08-31T17:00:00Z", transcript: "Hayden: I will prepare the dashboard. Carter: I will review the risks." }),
    });
    const result = await worker.fetch(request, environment(), {});
    const payload = await result.json();
    assert.equal(result.status, 201);
    assert.equal(payload.routed.item_count, 4);
    assert.deepEqual(payload.routed.destinations.map((item) => item.kind), ["meeting", "task", "task", "idea"]);
    const taskCreates = created.filter((item) => item.body?.parent?.database_id === ids.tasks);
    assert.equal(taskCreates.length, 2);
    assert.equal(taskCreates[0].body.properties.Status.status.name, "Not started");
    assert.equal(taskCreates[0].body.properties.Priority.select.name, "High");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("task endpoints require authentication", async () => {
  const result = await worker.fetch(new Request("https://example.test/tasks"), environment(), {});
  assert.equal(result.status, 401);
});

test("routing diagnostics require authentication", async () => {
  const result = await worker.fetch(new Request("https://example.test/diagnostics/routing"), environment(), {});
  assert.equal(result.status, 401);
});

test("explicit reprocessing bypasses source dedupe and reuses routed artifacts", async () => {
  const originalFetch = globalThis.fetch;
  const created = [];
  let sourceDedupeQueries = 0;
  let nextPage = 100;
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const body = init.body ? JSON.parse(init.body) : null;
    if (url.pathname.endsWith(`/blocks/${ids.inbox}/children`)) return response({ results: [] });
    if (url.pathname.endsWith("/pages") && init.method === "POST") {
      const isSource = body?.parent?.page_id === ids.inbox;
      const page = {
        id: isSource ? "77777777-7777-7777-7777-777777777777" : `bbbbbbbb-bbbb-bbbb-bbbb-${String(nextPage++).padStart(12, "0")}`,
        url: isSource ? "https://www.notion.so/retry-source" : `https://www.notion.so/retry-${nextPage}`,
      };
      created.push({ body, page });
      return response(page);
    }
    if (url.pathname.includes("/pages/") && !init.method) {
      return response({
        id: "77777777-7777-7777-7777-777777777777",
        parent: { page_id: ids.inbox },
        properties: { Name: { type: "title", title: [{ plain_text: "2026-08-31 10:00:00 · AnkerCore 1788200001" }] } },
        created_time: "2026-08-31T17:00:00Z",
        url: "https://www.notion.so/retry-source",
      });
    }
    if (url.pathname.includes("/blocks/") && url.pathname.endsWith("/children")) {
      return response({ results: [{ type: "paragraph", paragraph: { rich_text: [{ plain_text: "Hayden: I will prepare the dashboard. Carter: I will review the risks." }] } }] });
    }
    if (url.pathname.includes("/databases/") && url.pathname.endsWith("/query")) {
      const property = body?.filter?.property;
      if (property === "Source") {
        sourceDedupeQueries += 1;
        return response({ results: [{ id: "already-routed" }] });
      }
      if (property === "Artifact Key") {
        return response({ results: [{ id: `existing-${nextPage++}`, url: `https://www.notion.so/existing-${nextPage}` }] });
      }
      return response({ results: [] });
    }
    if (url.pathname.includes("/pages/") && init.method === "PATCH") return response({ id: "updated" });
    throw new Error(`Unexpected Notion request: ${init.method || "GET"} ${url.pathname}`);
  };

  try {
    const request = new Request("https://example.test/transcript", {
      method: "POST",
      headers: { authorization: `Bearer ${"x".repeat(32)}`, "content-type": "application/json" },
      body: JSON.stringify({
        file_id: "1788200001",
        recorded_at: "2026-08-31T17:00:00Z",
        transcript: "Hayden: I will prepare the dashboard. Carter: I will review the risks.",
        reprocess: true,
      }),
    });
    const result = await worker.fetch(request, environment(), {});
    const payload = await result.json();
    assert.equal(result.status, 201);
    assert.equal(payload.routed.item_count, 4);
    assert.equal(sourceDedupeQueries, 0);
    const routedCreates = created.filter((item) => [ids.meetings, ids.tasks, ids.ideas].includes(item.body?.parent?.database_id));
    assert.equal(routedCreates.length, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("reprocess accepts booleans only", async () => {
  const request = new Request("https://example.test/transcript", {
    method: "POST",
    headers: { authorization: `Bearer ${"x".repeat(32)}`, "content-type": "application/json" },
    body: JSON.stringify({
      file_id: "1788200002",
      transcript: "A valid transcript body.",
      reprocess: "true",
    }),
  });
  const result = await worker.fetch(request, environment(), {});
  assert.equal(result.status, 400);
  assert.equal((await result.json()).error, "invalid_reprocess");
});

test("supplied on-device analysis cannot invent a meeting or people", async () => {
  const originalFetch = globalThis.fetch;
  const created = [];
  let nextPage = 300;
  const transcript = "We need to wire up the databases to the next of MCP server.";
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const body = init.body ? JSON.parse(init.body) : null;
    if (url.pathname.endsWith(`/blocks/${ids.inbox}/children`)) return response({ results: [] });
    if (url.pathname.endsWith("/pages") && init.method === "POST") {
      const isSource = body?.parent?.page_id === ids.inbox;
      const page = {
        id: isSource ? "88888888-8888-8888-8888-888888888888" : `cccccccc-cccc-cccc-cccc-${String(nextPage++).padStart(12, "0")}`,
        url: isSource ? "https://www.notion.so/grounded-source" : `https://www.notion.so/grounded-${nextPage}`,
      };
      created.push({ body, page });
      return response(page);
    }
    if (url.pathname.includes("/pages/") && !init.method) {
      return response({
        id: "88888888-8888-8888-8888-888888888888",
        parent: { page_id: ids.inbox },
        properties: { Name: { type: "title", title: [{ plain_text: "2026-08-31 06:42:31 · AnkerCore 1788183751" }] } },
        created_time: "2026-08-31T13:42:31Z",
        url: "https://www.notion.so/grounded-source",
      });
    }
    if (url.pathname.includes("/blocks/") && url.pathname.endsWith("/children")) {
      return response({ results: [{ type: "paragraph", paragraph: { rich_text: [{ plain_text: transcript }] } }] });
    }
    if (url.pathname.includes("/databases/") && url.pathname.endsWith("/query")) return response({ results: [] });
    if (url.pathname.includes("/pages/") && init.method === "PATCH") return response({ id: "updated" });
    throw new Error(`Unexpected Notion request: ${init.method || "GET"} ${url.pathname}`);
  };

  try {
    const request = new Request("https://example.test/transcript", {
      method: "POST",
      headers: { authorization: `Bearer ${"x".repeat(32)}`, "content-type": "application/json" },
      body: JSON.stringify({
        file_id: "1788183751",
        recorded_at: "2026-08-31T13:42:31Z",
        transcript,
        analysis: {
          area: "Work",
          area_confidence: 0.9,
          summary: "We need to wire up the databases to the next MCP server.",
          project: "OnDeviceAnalysis",
          client: "MCP",
          people: ["Alice", "Bob", "Charlie"],
          meeting: {
            title: "OnDeviceAnalysis Meeting",
            participants: ["Alice", "Bob", "Charlie"],
            decisions: ["Wire up the databases to the next MCP server."],
            open_questions: [],
            follow_up: "Review the results of the database wire-up.",
          },
          tasks: [],
          ideas: [],
        },
      }),
    });
    const result = await worker.fetch(request, environment(), {});
    const payload = await result.json();
    assert.equal(result.status, 201);
    assert.equal(payload.routed.item_count, 1);
    assert.equal(payload.routed.destinations[0].kind, "task");
    assert.equal(payload.routed.area, "Needs Review");
    assert.equal(created.filter((item) => item.body?.parent?.database_id === ids.meetings).length, 0);
    assert.equal(created.filter((item) => item.body?.parent?.database_id === ids.tasks).length, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("editing one linked task in Recent Items updates only its destination", async () => {
  const originalFetch = globalThis.fetch;
  const verificationToken = "notion-webhook-test-token";
  const recentPageId = "99999999-9999-9999-9999-999999999999";
  const taskPageId = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb";
  const patches = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    if (url.pathname.endsWith(`/pages/${recentPageId}`) && !init.method) {
      return response({
        id: recentPageId,
        parent: { database_id: ids.recent },
        properties: {
          Name: { title: [{ plain_text: "Send the revised launch plan" }] },
          Type: { select: { name: "Task" } },
          Area: { select: { name: "Work" } },
          Summary: { rich_text: [{ plain_text: "Send the revised plan to the team." }] },
          Tasks: { relation: [{ id: taskPageId }] },
          "Task Status": { status: { name: "In progress" } },
          Priority: { select: { name: "High" } },
          Due: { date: { start: "2026-09-02" } },
          Owner: { rich_text: [{ plain_text: "Hayden" }] },
        },
      });
    }
    if (url.pathname.endsWith(`/pages/${taskPageId}`) && !init.method) {
      return response({ id: taskPageId, parent: { database_id: ids.tasks }, properties: {} });
    }
    if (url.pathname.endsWith(`/pages/${taskPageId}`) && init.method === "PATCH") {
      patches.push(JSON.parse(init.body));
      return response({ id: taskPageId });
    }
    throw new Error(`Unexpected Notion request: ${init.method || "GET"} ${url.pathname}`);
  };

  try {
    const body = JSON.stringify({ type: "page.properties_updated", entity: { id: recentPageId } });
    const signature = await notionSignature(body, verificationToken);
    let background;
    const result = await worker.fetch(new Request("https://example.test/notion", {
      method: "POST",
      headers: { "content-type": "application/json", "x-notion-signature": signature },
      body,
    }), { ...environment(), NOTION_VERIFICATION_TOKEN: verificationToken }, {
      waitUntil(promise) { background = promise; },
    });
    assert.equal(result.status, 202);
    await background;
    assert.equal(patches.length, 1);
    assert.equal(patches[0].properties.Name.title[0].text.content, "Send the revised launch plan");
    assert.equal(patches[0].properties.Status.status.name, "In progress");
    assert.equal(patches[0].properties.Priority.select.name, "High");
    assert.equal(patches[0].properties.Due.date.start, "2026-09-02");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

async function notionSignature(body, secret) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const bytes = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  return `sha256=${[...bytes].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
}

function response(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}
