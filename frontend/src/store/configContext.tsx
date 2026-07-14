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
};

const defaultValue = {
  githubAppName: "",
  cacheUrl: "",
  giteaUrl: "",
};

const ConfigContext = createContext<ConfigContextType>(defaultValue);

export const ConfigProvider = ({ children }: PropsWithChildren) => {
  const [githubAppName, setGithubAppName] = useState("");
  const [cacheUrl, setCacheUrl] = useState("");
  const [giteaUrl, setGiteaUrl] = useState("");
  useEffect(() => {
    void (async () => {
      const config = await getConfig();
      if (!config.ok) return;
      setGithubAppName(config.data.githubAppName);
      setCacheUrl(config.data.cacheUrl);
      setGiteaUrl(config.data.giteaUrl);
    })();
  }, [setGithubAppName, setCacheUrl, setGiteaUrl]);
  return (
    <ConfigContext.Provider value={{ githubAppName, cacheUrl, giteaUrl }}>
      {children}
    </ConfigContext.Provider>
  );
};

export const useConfig = () => {
  return useContext(ConfigContext);
};
