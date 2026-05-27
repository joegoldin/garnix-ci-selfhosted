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
};

const defaultValue = {
  githubAppName: "",
};

const ConfigContext = createContext<ConfigContextType>(defaultValue);

export const ConfigProvider = ({ children }: PropsWithChildren) => {
  const [githubAppName, setGithubAppName] = useState("");
  useEffect(() => {
    void (async () => {
      const config = await getConfig();
      if (!config.ok) return;
      setGithubAppName(config.data.githubAppName);
    })();
  }, [setGithubAppName]);
  return (
    <ConfigContext.Provider value={{ githubAppName }}>
      {children}
    </ConfigContext.Provider>
  );
};

export const useConfig = () => {
  return useContext(ConfigContext);
};
