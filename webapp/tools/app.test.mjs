import { test } from "node:test";
import assert from "node:assert/strict";
import { entryRef } from "../app.mjs";

test("entryRef accepts order refs, bind refs, and Telegram start_param", () => {
  assert.equal(entryRef(null, new URLSearchParams("order=o1&token=t")), "o1");
  assert.equal(entryRef(null, new URLSearchParams("bind=b1&token=t")), "b1");
  assert.equal(
    entryRef({ initDataUnsafe: { start_param: "tg-ref" } }, new URLSearchParams("order=o1&bind=b1")),
    "tg-ref"
  );
});
