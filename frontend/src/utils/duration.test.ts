import {
  diffTime,
  formatDurationLong,
  formatDurationShort,
  formatMinutes,
  fromSecs,
} from "./duration";

describe("duration", () => {
  describe("difftime", () => {
    it("returns the difference of two times", () => {
      const duration = diffTime(
        new Date("2024-01-02T03:34:05Z"),
        new Date("2024-01-02T03:04:05Z"),
      );
      expect(formatMinutes(duration)).toEqual("30.00");
    });
  });

  describe("formatDurationShort", () => {
    it("renders durations spanning hours", () => {
      const d = fromSecs(
        60 * 60 * 300 + // 300 hours
          60 * 4 + // 4 minutes
          5.678, // should not matter
      );
      expect(formatDurationShort(d)).toEqual("300h 4m");
    });

    it("renders durations spanning minutes", () => {
      const d = fromSecs(
        60 * 4 + // 4 minutes
          5 + // 5 seconds
          0.678, // should not matter
      );
      expect(formatDurationShort(d)).toEqual("4m 5s");
    });

    it("renders durations spanning seconds", () => {
      const d = fromSecs(
        5 + // 5 seconds
          0.678, // should not matter
      );
      expect(formatDurationShort(d)).toEqual("5s");
    });

    it("renders durations spanning milliseconds", () => {
      const d = fromSecs(0.678);
      expect(formatDurationShort(d)).toEqual("678ms");
    });
  });

  describe("formatDurationLong", () => {
    it("renders durations spanning years", () => {
      const d = fromSecs(
        2 * 365.25 * 24 * 60 * 60 + // 2 years
          3 * 40 * 24 * 60 * 60, // does not matter
      );
      expect(formatDurationLong(d)).toEqual("2 years");
    });

    it("renders durations spanning months", () => {
      const d = fromSecs(
        2 * 30.4375 * 24 * 60 * 60 + // 2 months
          3 * 24 * 60 * 60, // does not matter
      );
      expect(formatDurationLong(d)).toEqual("2 months");
    });

    it("renders durations spanning weeks", () => {
      const d = fromSecs(
        2 * 7 * 24 * 60 * 60 + // 2 weeks
          3 * 24 * 60 * 60, // does not matter
      );
      expect(formatDurationLong(d)).toEqual("2 weeks");
    });

    it("renders durations spanning days", () => {
      const d = fromSecs(
        2 * 24 * 60 * 60 + // 2 days
          3 * 60 * 60, // does not matter
      );
      expect(formatDurationLong(d)).toEqual("2 days");
    });

    it("renders durations spanning hours", () => {
      const d = fromSecs(
        2 * 60 * 60 + // 2 hours
          3 * 60, // does not matter
      );
      expect(formatDurationLong(d)).toEqual("2 hours");
    });

    it("renders durations spanning minutes", () => {
      const d = fromSecs(
        2 * 60 + // 2 minutes
          3, // does not matter
      );
      expect(formatDurationLong(d)).toEqual("2 minutes");
    });

    it("renders durations spanning seconds", () => {
      const d = fromSecs(
        2 + // 2 seconds
          0.678, // does not matter
      );
      expect(formatDurationLong(d)).toEqual("a few seconds");
    });
  });
});
