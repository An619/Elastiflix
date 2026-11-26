import { Link } from "react-router-dom";
import SearchBar from "./SearchBar";
import logo from '../assets/logo.svg'

function Nav({ fixed = false, showSearch = false }) {
    return (
        <div className={`nav ${fixed ? 'nav-fixed' : ''}`}>
            <Link to="/home">
                <img
                    className="nav__logo"
                    src={logo}
                    alt="Site Logo"
                />
            </Link>
            {showSearch && (
                <div className="search_bar">
                    <SearchBar />
                </div>
            )}
        </div>
    );
}

export default Nav;
