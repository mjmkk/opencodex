export function createClickSelftestController() {
  const state = {
    step: 0,
    statusText: "INIT",
    resultText: "PENDING",
    resultClass: "pending",
    confirmEnabled: false,
    confirmChecked: false,
    finishEnabled: false,
  };

  function snapshot() {
    return {
      step: state.step,
      statusText: state.statusText,
      resultText: state.resultText,
      resultClass: state.resultClass,
      confirmEnabled: state.confirmEnabled,
      confirmChecked: state.confirmChecked,
      finishEnabled: state.finishEnabled,
    };
  }

  function start() {
    if (state.step !== 0) {
      return snapshot();
    }

    state.step = 1;
    state.statusText = "STEP_1_OK";
    state.confirmEnabled = true;
    return snapshot();
  }

  function setConfirmChecked(checked) {
    if (!state.confirmEnabled) {
      return snapshot();
    }

    state.confirmChecked = Boolean(checked);

    if (state.step === 1 && state.confirmChecked) {
      state.step = 2;
      state.statusText = "STEP_2_OK";
      state.finishEnabled = true;
    }

    if (state.step === 1 && !state.confirmChecked) {
      state.finishEnabled = false;
    }

    return snapshot();
  }

  function finish() {
    if (state.step !== 2 || !state.finishEnabled) {
      return snapshot();
    }

    state.statusText = "PASS";
    state.resultText = "PASS";
    state.resultClass = "pass";
    return snapshot();
  }

  return {
    snapshot,
    start,
    setConfirmChecked,
    finish,
  };
}
