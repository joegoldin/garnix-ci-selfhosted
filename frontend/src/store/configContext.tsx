"use client";

import {
  createContext,
  useContext,
  PropsWithChildren,
  useState,
  useEffect,
} from "react";
import { getConfig } from "@/services/config";

type ConfigContextType = {
  githubAppName: string;
  cacheUrl: string;
  giteaUrl: string;
  selfHostMode: boolean;
  sshHost: string;
  hostingPublicIp: string | null;
  hostingDomain: string;
  hostingBases: string[];
};

const defaultValue = {
  githubAppName: "",
  cacheUrl: "",
  giteaUrl: "",
  selfHostMode: false,
  sshHost: "",
  hostingPublicIp: null,
  hostingDomain: "",
  hostingBases: [],
};

const ConfigContext = createContext<ConfigContextType>(defaultValue);

export const ConfigProvider = ({ children }: PropsWithChildren) => {
  const [githubAppName, setGithubAppName] = useState("");
  const [cacheUrl, setCacheUrl] = useState("");
  const [giteaUrl, setGiteaUrl] = useState("");
  const [selfHostMode, setSelfHostMode] = useState(false);
  const [sshHost, setSshHost] = useState("");
  const [hostingPublicIp, setHostingPublicIp] = useState<string | null>(null);
  const [hostingDomain, setHostingDomain] = useState("");
  const [hostingBases, setHostingBases] = useState<string[]>([]);
  useEffect(() => {
    void (async () => {
      const config = await getConfig();
      if (!config.ok) return;
      setGithubAppName(config.data.githubAppName);
      setCacheUrl(config.data.cacheUrl);
      setGiteaUrl(config.data.giteaUrl);
      setSelfHostMode(config.data.selfHostMode);
      setSshHost(config.data.sshHost);
      setHostingPublicIp(config.data.hostingPublicIp);
      setHostingDomain(config.data.hostingDomain);
      setHostingBases(config.data.hostingBases);
    })();
  }, [
    setGithubAppName,
    setCacheUrl,
    setGiteaUrl,
    setSelfHostMode,
    setSshHost,
    setHostingPublicIp,
    setHostingDomain,
    setHostingBases,
  ]);
  return (
    <ConfigContext.Provider
      value={{
        githubAppName,
        cacheUrl,
        giteaUrl,
        selfHostMode,
        sshHost,
        hostingPublicIp,
        hostingDomain,
        hostingBases,
      }}
    >
      {children}
    </ConfigContext.Provider>
  );
};

export const useConfig = () => {
  return useContext(ConfigContext);
};
