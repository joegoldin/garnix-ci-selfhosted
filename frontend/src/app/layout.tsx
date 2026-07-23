import { Metadata } from "next";
import { Body } from "@/components/body";
import { Providers } from "@/store/providers";
import opengraph from "./og.png";
import "@/utils/colors.css";
import "@/utils/sizes.css";
import "./globals.css";

// This is a standalone Next.js server (not a static export). The root layout
// used to call headers() (for the Plausible script nonce), which implicitly
// forced dynamic rendering app-wide; removing Plausible removed that call, so
// `next build` began statically prerendering pages that use useSearchParams()
// and failed the CSR-bailout check. Force dynamic rendering to restore the
// prior behavior.
export const dynamic = "force-dynamic";

const baseMetadata = {
  title: "garnix | the nix CI",
  description: "Simple, fast, and green CI and caching for nix projects",
  images: [opengraph.src],
  metadataBase: new URL("https://garnix.io"),
};

export const metadata: Metadata = {
  ...baseMetadata,
  alternates: {
    types: {
      "application/rss+xml": [{ title: "Garnix Blog", url: "/feed.xml" }],
    },
  },
  twitter: baseMetadata,
  openGraph: baseMetadata,
};

const RootLayout = ({ children }: { children: React.ReactNode }) => {
  return (
    <html lang="en">
      <Providers>
        <Body>{children}</Body>
      </Providers>
    </html>
  );
};

export default RootLayout;
