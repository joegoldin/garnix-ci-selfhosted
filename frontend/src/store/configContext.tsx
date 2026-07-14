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
};

const defaultValue = {
  githubAppName: "",
  cacheUrl: "",
  giteaUrl: "",
  selfHostMode: false,
};

const ConfigContext = createContext<ConfigContextType>(defaultValue);

export const ConfigProvider = ({ children }: PropsWithChildren) => {
  const [githubAppName, setGithubAppName] = useState("");
  const [cacheUrl, setCacheUrl] = useState("");
  const [giteaUrl, setGiteaUrl] = useState("");
  const [selfHostMode, setSelfHostMode] = useState(false);
  useEffect(() => {
    void (async () => {
      const config = await getConfig();
      if (!config.ok) return;
      setGithubAppName(config.data.githubAppName);
      setCacheUrl(config.data.cacheUrl);
      setGiteaUrl(config.data.giteaUrl);
      setSelfHostMode(config.data.selfHostMode);
    })();
  }, [setGithubAppName, setCacheUrl, setGiteaUrl, setSelfHostMode]);
  return (
    <ConfigContext.Provider
      value={{ githubAppName, cacheUrl, giteaUrl, selfHostMode }}
    >
      {children}
    </ConfigContext.Provider>
  );
};

export const useConfig = () => {
  return useContext(ConfigContext);
};
