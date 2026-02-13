import test from "node:test";
import assert from "node:assert/strict";

import { createClickSelftestController } from "../selftest/browser-click-selftest.js";

test("初始状态正确", () => {
  const controller = createClickSelftestController();
  assert.deepEqual(controller.snapshot(), {
    step: 0,
    statusText: "INIT",
    resultText: "PENDING",
    resultClass: "pending",
    confirmEnabled: false,
    confirmChecked: false,
    finishEnabled: false,
  });
});

test("完整流程可达 PASS", () => {
  const controller = createClickSelftestController();

  controller.start();
  controller.setConfirmChecked(true);
  controller.finish();

  assert.equal(controller.snapshot().statusText, "PASS");
  assert.equal(controller.snapshot().resultText, "PASS");
  assert.equal(controller.snapshot().resultClass, "pass");
});

test("未完成前置步骤不能 finish", () => {
  const controller = createClickSelftestController();

  controller.finish();
  assert.equal(controller.snapshot().statusText, "INIT");

  controller.start();
  controller.finish();
  assert.equal(controller.snapshot().statusText, "STEP_1_OK");
});
