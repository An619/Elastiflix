import connector from '../services/SearchConnector'; // Import the shared connector
import { SearchProvider, WithSearch } from "@elastic/react-search-ui";

function Header() {
  const config = {
    initialState: { resultsPerPage: 1 }, // Only fetch 1 result
    searchQuery: {
      filters: [
        {
          field: "id",
          values: ["568124"], // Featured movie: Encanto
          type: "all",
        }
      ],
      result_fields: {
        title: { raw: {} },
        poster_path: { raw: {} },
        backdrop_path: { raw: {} },
        overview: { raw: {} },
        release_date: { raw: {} },
      },
    },
    apiConnector: connector, // Use the imported shared connector
    alwaysSearchOnInitialLoad: true,
    trackUrlState: false,
  };

  return (
    <SearchProvider config={config}>
      <WithSearch
        mapContextToProps={({ results }) => ({ results })} // Map only the results
      >
        {({ results }) => {
          if (!results || results.length === 0) return <div>Loading...</div>;

          // Get the first result only
          const movie = results[0];
          const raw = (field) => movie[field]?.raw ?? null;
          const backdrop = raw("backdrop_path") || raw("poster_path");

          return (
            <header
              className="banner"
              style={backdrop ? { backgroundImage: `url(https://image.tmdb.org/t/p/original/${backdrop})` } : {}}
            >
              <div className="banner__contents">
                <h1 className="banner__title">{raw("title") ?? "Elastiflix"}</h1>
                <div className="banner__buttons">
                  <button className="banner__button">Play</button>
                  <button className="banner__button">My List</button>
                </div>
                <p className="banner__description">{raw("overview") ?? ""}</p>
              </div>
              <div className="banner--fadeBottom"></div>
            </header>
          );
        }}
      </WithSearch>
    </SearchProvider>
  );
}

export default Header;
