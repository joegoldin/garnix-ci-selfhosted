export const trackClick = (eventName: string) => track("click", eventName);
export const trackSubmit = (eventName: string) => track("submit", eventName);

export const track = (eventType: string, eventName: string) => {
  if (typeof window.plausible !== "function") return;
  window.plausible(`${eventType}#${eventName}`);
  window.plausible(`${eventType}#${window.location.pathname}#${eventName}`);
};
