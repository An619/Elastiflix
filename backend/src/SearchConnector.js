import ElasticsearchAPIConnector from "@elastic/search-ui-elasticsearch-connector";
import { secretValue } from "./secretValue.js";

const SearchConnector = new ElasticsearchAPIConnector({
  host: process.env.ES_HOST || "http://localhost:9200",
  index: process.env.ES_INDEX || "elastiflix-movies",
  apiKey: secretValue("ES_API_KEY")
});

export default SearchConnector;