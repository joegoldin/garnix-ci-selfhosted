import "@testing-library/jest-dom";
import { fireEvent, render, screen } from "@testing-library/react";
import { Ok } from "@/services";
import { getRepos } from "@/services/account";
import { RepoPicker } from ".";

jest.mock("../../../../../services/account", () => ({
  getRepos: jest.fn(),
}));

const mockGetRepos = jest.mocked(getRepos);

describe("RepoPicker", () => {
  beforeEach(() => {
    mockGetRepos.mockResolvedValue(
      Ok([
        { repoUser: "joegoldin", repoName: "dotfiles" },
        { repoUser: "joegoldin", repoName: "garnix-ci-selfhosted" },
        { repoUser: "other", repoName: "unrelated" },
      ]),
    );
  });

  it("filters repositories by owner or name", async () => {
    render(<RepoPicker value={null} onChange={jest.fn()} />);

    const search = await screen.findByRole("searchbox", {
      name: "Filter repositories",
    });
    fireEvent.change(search, { target: { value: "garnix" } });

    expect(
      screen.getByText("joegoldin / garnix-ci-selfhosted"),
    ).toBeInTheDocument();
    expect(screen.queryByText("joegoldin / dotfiles")).not.toBeInTheDocument();
    expect(screen.queryByText("other / unrelated")).not.toBeInTheDocument();
  });
});
