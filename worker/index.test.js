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

function response(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}
