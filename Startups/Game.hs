{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}

module Startups.Game where

import Startups.GameTypes
import Startups.Utils
import Startups.Base
import Startups.Cards
import Startups.CardList
import Startups.PrettyPrint

import Control.Lens
import Control.Monad
import Control.Applicative
import Control.Monad.Error (throwError)
import System.Random (randomR)
import qualified Data.Map as M
import qualified Data.MultiSet as MS
import Data.Monoid
import Data.List.Split (chunksOf)
import Data.Maybe (fromMaybe)
import Data.Traversable (for)

-- | This is the initialization function. The state should be initialized
-- with the correct list of players, but the player state or discard pile
-- can be arbitrary, as they will be initialized here.
--
-- It ensures some invariants, such as :
-- * all players have the first stage of their company in their card list
-- * all players have a valid left and right neighbor
initGame :: GameStateOnly m => m ()
initGame = do
    discardpile .= []
    pidlst <- playerList >>= shuffle
    companies <- shuffle [Facebook .. Microsoft]
    let leftNeighbors = tail (concat $ repeat pidlst)
        rightNeighbors = last pidlst : concat (repeat pidlst)
        playerInformation = getZipList ((,,,) <$> ZipList pidlst
                                              <*> ZipList leftNeighbors
                                              <*> ZipList rightNeighbors
                                              <*> ZipList companies)
    forM_ playerInformation $ \(pid, ln, rn, company) -> do
        side <- (\x -> if x == 0 then A else B) <$> getRandom 2
        let profile = CompanyProfile company side
        playermap . ix pid %=   (pCompany .~ profile)
                              . (pCards .~ [getResourceCard profile Project])
                              . (pFunds .~ 3)
                              . (pNeighborhood .~ (ln, rn))
                              . (pCompanyStage .~ Project)

-- | A simple wrapper for getting random numbers.
getRandom :: GameStateOnly m => Int -> m Int
getRandom x = do
    gen <- use rnd
    let (o, gen') = randomR (0,x - 1) gen
    rnd .= gen'
    return o

-- | A helper function that retrieves the player list
playerList :: GameStateOnly m => m [PlayerId]
playerList = map fst . itoList <$> use playermap

-- | This shuffles a list of values, using the randomRoll function.
shuffle :: (GameStateOnly m, Eq a) => [a] -> m [a]
shuffle [] = return []
shuffle xs = do
    n <- getRandom (length xs)
    let x = xs !! n
        xs' = filter (/= x) xs
    rest <- shuffle xs'
    return (x : rest)

-- | Shuffle the cards corresponding to an age, and deal them in hands of
-- 7 cards.
dealCards :: GameStateOnly m => Age -> m (M.Map PlayerId [Card])
dealCards age = do
    playerlst <- playerList
    let agecards = filter (\c -> c ^? cAge == Just age && correctPlayerCount c) allcards
        correctPlayerCount = (== Just True) . preview (cMinplayers . to (<= fromIntegral playerCount))
        communityCount = playerCount + 2
        playerCount = length playerlst
    com <- if age == Age3
               then take communityCount <$> shuffle communities
               else return []
    M.fromList . zip playerlst . chunksOf 7 <$> shuffle (com <> agecards)

-- | A helper for retrieving the player state.
getPlayerState :: NonInteractive m => PlayerId -> m PlayerState
getPlayerState pid = preuse (playermap . ix pid) >>= \m -> case m of
                                                               Nothing -> throwError ("Could not retrieve" <+> showPlayerId pid <+> "state")
                                                               Just x -> return x

-- | This transforms an exchange with a pair of neighbors with a list of
-- collected resources, and money to distribute with these neighbors.
--
-- The money is not immediately added to the neighbor to prevent a race
-- condition where a player could try an exchange that is more expensive
-- than what he owns, hoping some other player with exchange something with
-- him.
resolveExchange :: NonInteractive m => PlayerId -> Exchange -> m (MS.MultiSet Resource, AddMap PlayerId Funding)
resolveExchange pid exch = mconcat  . M.elems <$> itraverse resolveExchange' exch
    where
        resolveExchange' neigh reslist = do
            stt <- use playermap
            let cost = getSum $ reslist ^. folded . to (Sum . getExchangeCost pid neigh stt)
                playermoney = fromMaybe 0 (stt ^? ix pid . pFunds)
                neighname = stt ^. ix pid . neighbor neigh
                neigresources = stt ^. ix neighname . to (availableResources Exchange)
            when (cost > playermoney) (throwError (showPlayerId pid <+> "tried to perform an exchange without enough funding"))
            unless (any (reslist `MS.isSubsetOf`) neigresources) (throwError (showPlayerId pid <> "'s neighbor doesn't have enough resources"))
            playermap . ix pid . pFunds -= cost
            pure (reslist, AddMap (M.singleton neighname cost))

-- | Try to play a card, with some extra resources, provided that the
-- player has enough.
playCard :: NonInteractive m => Age -> PlayerId -> MS.MultiSet Resource -> Card -> m ()
playCard age pid extraResources card = do
    -- compute available resources
    playerState <- getPlayerState pid
    -- remove the chosen card from the card list, and remove the money from
    -- the player account
    let Cost _ fundCost = card ^. cCost
    let -- this tests whether a player has the opportunity capability ready
        hasOpportunity = has (cardEffects . _Opportunity . ix age) playerState && has cType card
        -- checks if a player has enough resources to play a card
        enoughResources = fundCost <= playerState ^. pFunds && isAffordable playerState extraResources card
        -- checks if a card is free (owns another card that permits free
        -- construction)
        isFree = case card ^? cName of
                     Just n -> freeConstruction playerState ^. contains n
                     Nothing -> False
        -- checks if a player can build a given card. This is in the 'let'
        -- part to take advantage of guards.
        checkPrice | enoughResources = playermap . ix pid . pFunds -= fundCost
                   | isFree = return ()
                   | hasOpportunity = playermap . ix pid . cardEffects . _Opportunity . at age .= Nothing
                   | otherwise = throwError (showPlayerId pid <+> "tried to play a card he did not have the resources for.")
    checkPrice
    -- add the card to the player hand
    playermap . ix pid . pCards %= (card :)

-- | This resolve the action played by the player, returning the new hand
-- (with the played card removed) and each player funding variation
-- (resulting from exchanges, or cards played). The final element in the
-- tuple is the card that actually got played. It might be :
-- * Nothing, for a card drop
-- * Just a card, for the card that got played
-- * Just a wonder stage
--
-- The reason it is done that way is that card payouts must be computed
-- after all other actions have been performed.
resolveAction :: NonInteractive m => Age -> PlayerId -> ([Card], (PlayerAction, Exchange)) -> m ([Card], AddMap PlayerId Funding, Maybe Card)
resolveAction age pid (hand, (PlayerAction actiontype card, exch)) = do
    -- check that the player didn't cheat
    unless (card `elem` hand) (throwError (showPlayerId pid <+> "tried to play a card that was not in his hand:" <+> shortCard card))
    -- resolve the exchanges
    (extraResources, payout) <- resolveExchange pid exch
    -- and now process the effect
    let newhand = filter (/= card) hand
    (cardp, extrapay) <- case actiontype of
        Drop -> discardpile %= (card :) >> return (Nothing, 3)
        Play -> playCard age pid extraResources card >> return (Just card, 0)
        BuildCompany -> do
            stt <- getPlayerState pid
            let profile   = stt ^. pCompany
                curstage  = stt ^. pCompanyStage
                maxstage  = getMaxStage profile
                nextstage = succ curstage
                ccard     = getResourceCard profile nextstage
            when (curstage == maxstage) (throwError (showPlayerId pid <+> "tried to increase the company stage beyond the limit."))
            playermap . ix pid . pCompanyStage %= succ
            playCard age pid extraResources ccard
            return (Just ccard, 0)
    return (newhand, payout <> AddMap (M.singleton pid extrapay), cardp)

-- | Play the end of age poaching, and returns the tokens that must be
-- distributed.
resolvePoaching :: Age -> M.Map PlayerId PlayerState -> M.Map PlayerId [PoachingOutcome]
resolvePoaching age plyrs =
    let poachingScores = fmap (view (cardEffects . _Poaching)) plyrs
        getScores pid ps =
            let nscores = ps ^.. pNeighborhood . both . to (cmpScore . getnscore) . folded
                curScore = poachingScores ^. ix pid
                cmpScore s | s > curScore = Just Defeat
                           | s < curScore = Just (Victory age)
                           | otherwise = Nothing
                getnscore x = poachingScores ^. ix x
            in  nscores
    in  M.mapWithKey getScores plyrs

-- | Play a turn :
-- * Ask the player what he'd like to do with the proposed hand.
-- * Remove the card the player chose from the hand, and play it.
--
-- Not that all cards effects are revealed simultaneously, and all cards
-- that let player gain money must be played after all cards are played.
playTurn :: Age -> Turn -> M.Map PlayerId [Card] -> GameMonad p (M.Map PlayerId [Card])
playTurn age turn rawcardmap = do
    stt <- use id
    -- compute the list of players that are playing this turn. Only players
    -- with the Efficiency power will be able to play the 7th turn.
    let cardmap = if turn == 7
                      then M.filterWithKey (\pid _ -> has (playerEffects pid . _Efficiency) stt) rawcardmap
                      else rawcardmap
        convertCards crds = case crds ^? _NonEmpty of
            Just n -> return n
            Nothing -> throwError "We managed to get an empty hand to play, this should never happen"
    -- first gather all decisions promises
    pdecisions <- ifor cardmap $ \pid crds -> (crds,) <$> (convertCards crds >>= playerDecision age turn pid)
    -- then await on all promised
    decisions <- traverse (\(crds,p) -> (,) <$> pure crds <*> getPromise p) pdecisions
    results <- itraverse (resolveAction age) decisions
    -- first add the money gained from exchanges
    ifor_ (results ^. traverse . _2) $ \pid payout ->
        playermap . ix pid . pFunds += payout
    -- then add the money gained from cards
    o <- ifor results $ \pid (hand, _, card) -> do
        void $ for card $ \c -> do
            f <- getCardFunding pid c <$> use playermap
            playermap . ix pid . pFunds += f
        return hand
    actionRecap age turn (fmap snd decisions)
    -- check for recycling
    -- Note that it is buggy : when played at the end of an age, it should
    -- give access to all the discarded cards. Now that it's resolved here,
    -- it can't.
    let recyclers = M.keys $ M.filter (has (_3 . _Just . cEffect . traverse . _Recycling)) results
    forM_ recyclers $ \recycler -> do
        curstate <- use id
        case curstate ^? discardpile . _NonEmpty of
            Just nedp -> do
                generalMessage (showPlayerId recycler <+> "is going to use his recycle ability.")
                card <- askCardSafe age recycler nedp "Choose a card to recycle (play for free)"
                generalMessage (showPlayerId recycler <+> "recycled" <+> shortCard card)
                playermap . ix recycler . pCards %= (card :)
                discardpile %= filter (/= card)
            Nothing -> tellPlayer recycler (emph "The discard pile was empty, you can't recycle.")
    return o

-- | Rotates the player hands, at the end of each turn.
rotateHands :: Age -> M.Map PlayerId [Card] -> GameMonad p (M.Map PlayerId [Card])
rotateHands age cardmap = itraverse rotatePlayer cardmap
    where
        rotatePlayer pid _ = do
            -- get the identifier of the correct neighbor
            neighid <- use (playermap . ix pid . neighbor direction)
            -- get his hand
            return (cardmap ^. ix neighid)
        direction = if age == Age2
                        then NLeft
                        else NRight

-- | Play a whole age
playAge :: Age -> GameMonad p ()
playAge age = do
    cards <- dealCards age
    let turnPlay crds turn = do
            ncrds <- playTurn age turn crds
            -- The 7th turn is a hack for the efficiency capacity. In that
            -- case, the hands should not be rotated as the rules stipulate
            -- that the player can play the two cards he has in hands.
            if turn == 6
                then return ncrds
                else rotateHands age ncrds
    remaining <- foldM turnPlay cards [1 .. 7]
    discardpile <>= toListOf (traverse . traverse) remaining
    -- resolve the "military" part
    let displayPoaching (pid, tokens) = showPlayerId pid <+> "received the following poaching tokens" <+> foldPretty tokens
    poachingTokens <- resolvePoaching age <$> use playermap
    ifor_ poachingTokens $ \pid toks -> playermap . ix pid . pPoachingResults <>= toks
    generalMessage $ vcat $ map displayPoaching $ filter (not . null . snd) $ itoList poachingTokens

-- | Resolves the effect of the CopyCommunity effect that let a player copy
-- an arbitrary community card from one of his neighbors.
checkCopyCommunity :: GameMonad p ()
checkCopyCommunity = do
    pm <- use playermap
    ifor_ pm $ \pid stt -> when (has (cardEffects . _CopyCommunity) stt) $ do
        -- get the violet cards from both neighbors
        let neighs = stt ^.. pNeighborhood . both
            violetCards = pm ^.. ifolded -- traverse de playerstate map
                               . ifiltered (const . (`elem` neighs)) -- keep only the neighbors
                               . pCards -- select each neighbor card list
                               . folded -- fold through it
                               . filtered (has (cType . _Community)) -- keep the violet cards
        case violetCards ^? _NonEmpty of
            Just nevc -> do
                generalMessage (showPlayerId pid <+> "is going to use his community copy ability.")
                card <- askCardSafe Age3 pid nevc "Which community would you like to copy ?"
                generalMessage (showPlayerId pid <+> "copied" <+> shortCard card)
                playermap . ix pid . pCards %= (card:)
            Nothing -> tellPlayer pid (emph "There were no violet cards bought by your neighbors. You can't use your copy capacity.")

victoryPoints :: GameStateOnly m => m (M.Map PlayerId (M.Map VictoryType VictoryPoint))
victoryPoints = use playermap >>= itraverse computeScore
    where
        computeScore pid playerState = do
            let poaching = (PoachingVictory, playerState ^. pPoachingResults . traverse . to poachScore)
                poachScore Defeat = -1
                poachScore (Victory Age1) = 1
                poachScore (Victory Age2) = 3
                poachScore (Victory Age3) = 5
                funding = (FundingVictory, fromIntegral (playerState ^. pFunds `div` 3))
                scienceTypes = playerState ^.. cardEffects . _RnD
                scienceJokers = length (playerState ^.. cardEffects . _ScientificBreakthrough)
                research = (RnDVictory, scienceScore scienceTypes scienceJokers)
            stt <- use playermap
            let cardPoints = playerState ^.. pCards . traverse . to (\c -> getCardVictory pid c stt) . folded
            return $ M.fromListWith (+) $ poaching : funding : research : cardPoints

-- | The main game function, runs a game. The state must be initialized in
-- the same way as the 'initGame' function.
playGame :: GameMonad p (M.Map PlayerId (M.Map VictoryType VictoryPoint))
playGame = do
    initGame
    actionRecap Age1 1 mempty
    mapM_ playAge [Age1 .. Age3]
    checkCopyCommunity
    victoryPoints
