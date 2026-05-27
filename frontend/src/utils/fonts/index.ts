import localFont from "next/font/local";

export const MatterSQMono = localFont({
  src: [
    {
      path: "./MatterSQMono-Light.woff",
      weight: "300",
    },
    {
      path: "./MatterSQMono-LightItalic.woff",
      style: "italic",
      weight: "300",
    },
    {
      path: "./MatterSQMono-Regular.woff",
      weight: "400",
    },
    {
      path: "./MatterSQMono-RegularItalic.woff",
      style: "italic",
      weight: "400",
    },
  ],
  declarations: [{ prop: "descent-override", value: "0%" }],
});

export const Berlin = localFont({
  src: [
    {
      path: "./BerlinTypeWeb-Regular.woff",
      weight: "400",
    },
  ],
});
