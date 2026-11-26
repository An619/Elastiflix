/**
 * Component tests with a stubbed search connector (no network).
 * jest.mock is hoisted; the factory replaces the shared connector that
 * every component imports from services/SearchConnector.
 */
import React from "react";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

const stubMovie = (id, title, poster = "/poster.jpg") => ({
  id: { raw: String(id) },
  title: { raw: title, snippet: [{ text: title }] },
  poster_path: { raw: poster, snippet: [{ text: poster }] },
  backdrop_path: { raw: "/backdrop.jpg", snippet: [{ text: "/backdrop.jpg" }] },
  overview: { raw: `${title} overview`, snippet: [{ text: `${title} overview` }] },
  release_date: { raw: "2021-05-01", snippet: [{ text: "2021-05-01" }] },
  cast: { raw: ["Actor One", "Actor Two"], snippet: [{ text: "Actor One" }] },
  plot: { raw: `${title} plot` },
  _meta: { id: String(id), rawHit: {} },
});

const searchResponse = (results) => ({
  results,
  totalResults: results.length,
  resultSearchTerm: "",
  wasSearched: true,
  totalPages: 1,
  pagingStart: 1,
  pagingEnd: results.length,
  facets: {},
});

jest.mock("../services/SearchConnector", () => ({
  __esModule: true,
  default: {
    // NOTE: react-scripts sets resetMocks: true, which wipes jest.fn
    // implementations. Plain functions survive; do not switch back to jest.fn.
    onSearch: async () => searchResponse([stubMovie(1, "Mock Movie")]),
    onAutocomplete: async () => ({
      autocompletedSuggestions: {},
      autocompletedResults: [stubMovie(1, "Mock Movie")],
      autocompletedResultsRequestId: "",
      autocompletedSuggestionsRequestId: "",
    }),
  },
}));

import Nav from "../components/Nav";
import Popular from "../components/Popular";
import Recent from "../components/Recent";
import Header from "../components/Header";
import Movie from "../components/Movie";

describe("Nav", () => {
  it("renders the search input when showSearch is set", () => {
    render(
      <MemoryRouter>
        <Nav showSearch fixed />
      </MemoryRouter>
    );
    expect(screen.getByPlaceholderText(/search by title/i)).toBeInTheDocument();
  });

  it("hides the search input without showSearch", () => {
    render(
      <MemoryRouter>
        <Nav />
      </MemoryRouter>
    );
    expect(screen.queryByPlaceholderText(/search by title/i)).not.toBeInTheDocument();
  });
});

describe("Popular", () => {
  it("renders popular movies from the connector", async () => {
    render(
      <MemoryRouter>
        <Popular />
      </MemoryRouter>
    );
    expect(screen.getByText("Popular movies")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByAltText("Mock Movie")).toBeInTheDocument());
  });
});

describe("Recent", () => {
  it("renders recent movies from the connector", async () => {
    render(
      <MemoryRouter>
        <Recent />
      </MemoryRouter>
    );
    expect(screen.getByText("Recent movies")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByAltText("Mock Movie")).toBeInTheDocument());
  });
});

describe("Header", () => {
  it("renders the featured movie banner", async () => {
    render(
      <MemoryRouter>
        <Header />
      </MemoryRouter>
    );
    await waitFor(() => expect(screen.getByText("Mock Movie")).toBeInTheDocument());
    expect(screen.getByText("Mock Movie overview")).toBeInTheDocument();
  });
});

describe("Movie", () => {
  it("renders the movie detail page", async () => {
    render(
      <MemoryRouter initialEntries={["/movie?id=1"]}>
        <Movie />
      </MemoryRouter>
    );
    await waitFor(() => expect(screen.getByText("Mock Movie")).toBeInTheDocument());
    expect(screen.getByText("Mock Movie overview")).toBeInTheDocument();
    expect(screen.getByText("Actor One")).toBeInTheDocument();
    expect(screen.getByText("Mock Movie plot")).toBeInTheDocument();
  });
});

import App from "../App";
import SearchPage from "../components/SearchPage";
import Layout from "../components/Layout";

describe("Layout", () => {
  it("renders children and the TMDB attribution", () => {
    render(
      <MemoryRouter>
        <Layout>
          <div>layout-child</div>
        </Layout>
      </MemoryRouter>
    );
    expect(screen.getByText("layout-child")).toBeInTheDocument();
    expect(screen.getByText(/TMDB API/)).toBeInTheDocument();
  });
});

describe("SearchPage", () => {
  it("renders the search box and lists results from the connector", async () => {
    render(
      <MemoryRouter initialEntries={["/search"]}>
        <SearchPage />
      </MemoryRouter>
    );
    expect(screen.getByPlaceholderText(/movie, cast or theme/i)).toBeInTheDocument();
    await waitFor(() => expect(screen.getByText("Mock Movie")).toBeInTheDocument());
  });
});

describe("App", () => {
  it("redirects / to /home and renders the home sections", async () => {
    window.history.pushState({}, "", "/");
    render(<App />);
    await waitFor(() => expect(screen.getByText("Popular movies")).toBeInTheDocument());
    expect(screen.getByText("Recent movies")).toBeInTheDocument();
    expect(window.location.pathname).toBe("/home");
  });
});
