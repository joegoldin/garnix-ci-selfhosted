import { formatPrice, formatTaxType } from "./currency";

describe("utils/currency", () => {
  describe("formatPrice", () => {
    it("formats prices in USD", () => {
      expect(formatPrice({ unit_amount: 2500, currency: "usd" })).toEqual(
        "25.00 USD",
      );
    });

    it("formats prices in other currencies", () => {
      expect(formatPrice({ unit_amount: 2500, currency: "foo" })).toEqual(
        "25.00 FOO",
      );
    });

    it("displays cents", () => {
      expect(formatPrice({ unit_amount: 1234, currency: "usd" })).toEqual(
        "12.34 USD",
      );
    });

    it("pads cent prices with zeros", () => {
      expect(formatPrice({ unit_amount: 1204, currency: "usd" })).toEqual(
        "12.04 USD",
      );
      expect(formatPrice({ unit_amount: 1230, currency: "usd" })).toEqual(
        "12.30 USD",
      );
    });

    it("rounds dollars correctly", () => {
      expect(formatPrice({ unit_amount: 199, currency: "usd" })).toEqual(
        "1.99 USD",
      );
    });
  });

  describe("formatTaxType", () => {
    it("upper cases all letters when there's no underscores", () => {
      expect(formatTaxType("vat")).toEqual("VAT");
      expect(formatTaxType("gst")).toEqual("GST");
    });

    it("replaces underscores with spaces", () => {
      expect(formatTaxType("sales_tax")).toEqual("Sales Tax");
      expect(formatTaxType("amusement_tax")).toEqual("Amusement Tax");
    });

    it("displays a generic text when the argument is null", () => {
      expect(formatTaxType(null)).toEqual("Tax");
    });
  });
});
