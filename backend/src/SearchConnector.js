import ElasticsearchAPIConnector from "@elastic/search-ui-elasticsearch-connector";

const SearchConnector = new ElasticsearchAPIConnector({
  host: process.env.ES_HOST || "http://localhost:9200",
  index: process.env.ES_INDEX || "elastiflix-movies",
  apiKey: process.env.ES_API_KEY
});

export default SearchConnector;