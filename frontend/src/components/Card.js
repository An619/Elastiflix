import * as React from "react";
import { Link } from "react-router-dom";
import ComingSoon from '../assets/coming-soon.png'

function Card(props) {
  const movie = props.movie || {};
  const raw = (field) => movie[field]?.raw ?? null;

  const cast = raw("cast") ?? [];
  const title = raw("title") ?? "Untitled";
  const overview = raw("overview") ?? "";
  const posterPath = raw("poster_path");
  const id = raw("id");
  const renderCast = cast.length > 0 && (
    <div className="cast"><p>Starring {cast.slice(0, 4).map(c => c + ", ")} ... </p></div>
  );

  const releaseDateRaw = raw("release_date");
  const releaseDate = releaseDateRaw ? new Date(releaseDateRaw) : null;
  const isValidDate = releaseDate && !Number.isNaN(releaseDate.getTime());
  const isUpcoming = isValidDate && releaseDate > new Date();

  const card = (
    <div className="card">
      <div className="wrapper">
        <div className="image">
          <div className="poster">
            <img loading="lazy" className="poster" src={!posterPath ? ComingSoon : `https://image.tmdb.org/t/p/w300_and_h450_bestv2/${posterPath}`} alt={title} />
          </div>
        </div>
        <div className="details">
          <div className="wrapper">
            <div className="title">
              <div>
                <h2>{title}</h2>
              </div>
              {isValidDate && (
                <span className="release_date">
                  {isUpcoming ? 'Releasing ' : 'Released '}
                  {new Intl.DateTimeFormat("en-GB", {
                    year: "numeric",
                    month: "long",
                    day: "2-digit"
                  }).format(releaseDate)}</span>
              )}
            </div>
          </div>
          <div className="overview">
            <p>{overview}</p>
          </div>
          {renderCast}
        </div>
      </div>
    </div>
  );

  return id !== null && id !== undefined ? (
    <Link to={`/movie?id=${encodeURIComponent(id)}`} style={{ textDecoration: "none", color: "inherit" }}>
      {card}
    </Link>
  ) : card;
}

export default Card
