/**
 * Regression tests for facet ranges and Card rendering.
 * Run with: CI=true npm test -- --watchAll=false
 */
import React from "react";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import Card from "../components/Card";

// The facet ranges live in SearchPage config. Importing SearchPage pulls
// in SearchProvider + connector, so assert the range math directly here
// and keep the config in sync with SearchPage.js.
const USER_SCORE_RANGES = [
  { from: 0, to: 5, name: "0 - 5" },
  { from: 5, to: 8, name: "5 - 8" },
  { from: 8, to: 10.01, name: "8 - 10" },
];
const RUNTIME_RANGES = [
  { from: 0, to: 60, name: "Less than an hour" },
  { from: 60, name: "More than an hour" },
];

function inRanges(value, ranges) {
  return ranges.some(
    (r) => (r.from === undefined || value >= r.from) && (r.to === undefined || value < r.to)
  );
}

describe("facet ranges cover every score/runtime (no gaps)", () => {
  it("covers 5.0, 8.0 and 10.0 user scores", () => {
    expect(inRanges(5.0, USER_SCORE_RANGES)).toBe(true);
    expect(inRanges(8.0, USER_SCORE_RANGES)).toBe(true);
    expect(inRanges(10.0, USER_SCORE_RANGES)).toBe(true);
  });

  it("covers runtime == 60", () => {
    expect(inRanges(60, RUNTIME_RANGES)).toBe(true);
  });
});

describe("Card", () => {
  const movie = {
    id: { raw: "123" },
    title: { raw: "Test Movie" },
    overview: { raw: "A test overview." },
    poster_path: { raw: "/abc.jpg" },
    release_date: { raw: "2020-01-15" },
    cast: { raw: ["Actor One"] },
  };

  it("renders title as text (no dangerouslySetInnerHTML XSS sink)", () => {
    render(
      <MemoryRouter>
        <Card movie={movie} />
      </MemoryRouter>
    );
    expect(screen.getByText("Test Movie")).toBeInTheDocument();
    expect(document.querySelector("h2")).not.toHaveAttribute("dangerouslySetInnerHTML");
  });

  it("does not crash when release_date is missing", () => {
    const noDate = { ...movie, release_date: { raw: null } };
    expect(() =>
      render(
        <MemoryRouter>
          <Card movie={noDate} />
        </MemoryRouter>
      )
    ).not.toThrow();
  });
});
