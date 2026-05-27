import { APIResult } from ".";

export const isNoSuchUserError = (response: APIResult<unknown>) => {
  return (
    !response.ok && response.error.message.includes("No user with github login")
  );
};
