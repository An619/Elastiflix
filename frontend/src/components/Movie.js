import { SearchProvider, WithSearch } from "@elastic/react-search-ui";
import React from "react";
import { useLocation } from "react-router-dom";
import Nav from "./Nav"
import connector from '../services/SearchConnector'; // Import the shared connector

function Movie() {

    const location = useLocation();
    const movieId = new URLSearchParams(location.search).get("id");

    const config = {
        initialState: {},
        searchQuery: {
            filters: [
                {
                    type: "all",
                    field: "id",
                    values: [movieId]
                }
            ],
            result_fields: {
                title: {
                    snippet: {}
                },

                backdrop_path: {
                    snippet: {}
                },
                overview: {
                    snippet: {}
                },
                release_date: {
                    snippet: {}
                },
                cast: {
                    snippet: {}
                },
                plot: {
                    raw: {}
                },
                id: {
                    snippet: {}
                }
            },
            result_size: 1
        },
        apiConnector: connector, // Use the shared connector
        alwaysSearchOnInitialLoad: true,
        trackUrlState: false
    };

    return (
        <SearchProvider config={config}>

            <Nav showSearch={true} fixed={true} />
            <WithSearch mapContextToProps={({ results }) => ({ results })}>

                {({ results }) => {

                    if (!results || results.length === 0) return <div>Movie not found.</div>;

                    // Get the first result only
                    const movie = results[0];
                    const raw = (field) => movie[field]?.raw ?? null;

                    const backdrop = raw("backdrop_path");
                    const posterStyle = backdrop
                        ? { backgroundImage: `url(https://image.tmdb.org/t/p/original/${backdrop})` }
                        : {};
                    const title = raw("title") ?? "Untitled";
                    const overview = raw("overview") ?? "";
                    const releaseDate = raw("release_date");
                    const cast = raw("cast") ?? [];
                    const plot = raw("plot");

                    return (
                        <div className="movie" style={posterStyle}>

                            <div className="container">
                                <div className="left">
                                    <h1 className="title">{title}</h1>
                                    <p className="overview">{overview}</p>

                                    {releaseDate && <>
                                        <h3>Release</h3>
                                        <p>{releaseDate}</p>
                                    </>}

                                    {cast.length > 0 && <>
                                        <h3>Cast</h3>
                                        {cast.slice(0, 10).map((name) => (
                                            <p key={name}>{name}</p>
                                        ))}
                                    </>}

                                </div>
                                <div className="right">
                                    {plot &&
                                        <div className="plot">
                                            <h3>Plot</h3>
                                            <p className="plot_text">{plot}</p>
                                        </div>
                                    }
                                </div>

                            </div>

                        </div>

                    )
                }}

            </WithSearch>
        </SearchProvider>
    );
}

export default Movie;
