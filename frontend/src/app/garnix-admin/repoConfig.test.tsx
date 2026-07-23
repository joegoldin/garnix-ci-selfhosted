import "@testing-library/jest-dom";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { Ok } from "@/services";
import RepoConfigEditor from "./repoConfig";

const reload = jest.fn();
const mockUseLoading = jest.fn();
const mockSetApproval = jest.fn();

jest.mock("../../hooks/useLoading", () => ({
  useLoading: (...args: Array<unknown>) => mockUseLoading(...args),
}));

jest.mock("../../services/admin", () => ({
  getPrivateInputForkRequests: jest.fn(),
  setPrivateInputForkApproval: (...args: Array<unknown>) =>
    mockSetApproval(...args),
}));

describe("external-fork private-input approvals", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockUseLoading.mockReturnValue({
      loading: false,
      data: Ok([
        {
          repoUser: "joegoldin",
          repoName: "example",
          forkFullName: "outsider/example-fork",
          allowed: false,
          blockedAt: new Date("2026-07-21T18:00:00Z"),
        },
      ]),
      reload,
    });
    mockSetApproval.mockResolvedValue(Ok({}));
  });

  it("lists only recorded requests instead of presenting a repo lookup form", () => {
    render(<RepoConfigEditor />);

    expect(screen.getByText("joegoldin/example")).toBeInTheDocument();
    expect(screen.getByText("Blocked")).toBeInTheDocument();
    expect(screen.queryByPlaceholderText("owner")).not.toBeInTheDocument();
    expect(screen.queryByText("Load")).not.toBeInTheDocument();
  });

  it("allows a recorded repo and tells the operator to retry", async () => {
    render(<RepoConfigEditor />);
    fireEvent.click(screen.getByRole("button", { name: "Allow" }));

    await waitFor(() =>
      expect(mockSetApproval).toHaveBeenCalledWith(
        "joegoldin",
        "example",
        "outsider/example-fork",
        true,
      ),
    );
    expect(
      await screen.findByText(/Retry the blocked build/),
    ).toBeInTheDocument();
    expect(reload).toHaveBeenCalled();
  });
});
