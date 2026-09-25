import type { Metadata } from "next";
import Script from "next/script";
import "./globals.css";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: "Social Media Video Tracker | Google Drive Studio",
  description: "Connected Google Drive workspace for social media creators with zero-lag uploads and automatic caption correlation.",
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="dark">
      <head>
        <Script src="https://accounts.google.com/gsi/client" strategy="afterInteractive" />
      </head>
      <body className="antialiased bg-[#090C12] text-slate-100">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
