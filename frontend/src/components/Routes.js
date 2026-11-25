import React from 'react';
import { Route, Switch, Redirect } from "react-router-dom";
import SearchPage from './SearchPage';
import Home from './Home.js';
import Layout from './Layout.js';
import Movie from './Movie';


const Routes = () => (
    <>
        <Switch>
          <Route exact path="/">
            <Redirect to="/home" />
          </Route>
          <RouteWrapper exact path="/home" component={Home} layout={Layout}/>
          <RouteWrapper exact path="/search" component={SearchPage} layout={Layout}/>
          <RouteWrapper exact path="/movie" component={Movie} layout={Layout}/>
        </Switch>
    </>
)

function RouteWrapper({
  component: Component,
  layout: LayoutComponent,
  ...rest
}) {
  return (
    <Route {...rest} render={(props) =>
      <LayoutComponent {...props}>
        <Component {...props} />
      </LayoutComponent>
    } />
  );
}

export default Routes;
